/* HiFi SRC Bypass - WebUI front-end  (universal)
 *
 * Talks to bin/hifi through the KernelSU / APatch root bridge.
 * Every command is a plain shell line, so it also works from a terminal.
 *
 * ---------------------------------------------------------------------------
 * Universal version.  Everything that used to be pinned to a single model is
 * now discovered on the device:
 *
 *   - module id is hifi_src_bypass (the controller resolves its own dir)
 *   - the audio policy file(s) to patch are found at runtime, so the policy
 *     box shows one or more real paths instead of one hard-coded OnePlus path
 *   - the patcher auto-detects the QTI vs AOSP dialect, so the same module
 *     works on OnePlus / Redmi / Xiaomi / Samsung / Pixel ...
 *
 * The root bridge contract is unchanged and is the one KernelSU documents:
 *
 *       ksu.exec(command, optionsAsJsonString, callbackNameAsString)
 *
 * i.e. the callback is the *NAME* of a function registered on `window`, and
 * the options argument is a JSON *string* -- that is literally what the
 * official `kernelsu` npm library does:
 *
 *       ksu.exec(command, JSON.stringify(options), callbackFuncName)
 *
 * We probe every plausible signature, remember the one that actually calls
 * back, and show the negotiation result in the on-page self test.
 * ---------------------------------------------------------------------------
 */
(function () {
  'use strict';

  var MOD_ID = 'hifi_src_bypass';
  var CANDIDATES = [
    '/data/adb/modules/' + MOD_ID,
    '/data/adb/modules_update/' + MOD_ID
  ];

  /* how long to wait for a callback before declaring a call form dead */
  var PROBE_GRACE = 1500;    /* negotiation - a working form answers at once  */
  var CMD_GRACE = 120000;    /* real command - apply/restore restart audio    */

  /* the ceilings bin/hifi accepts.  192 kHz is deliberately first-class:
     it is the universal 96 kHz compatibility step. */
  var RATES = [
    [96000, '96 kHz'],
    [176400, '176.4 kHz'],
    [192000, '192 kHz'],
    [352800, '352.8 kHz'],
    [384000, '384 kHz']
  ];

  /* global mixer work rate.  AudioPolicyManager picks the MAXIMUM of a mixed
     output's rate list, so the module rewrites the mixer mixPort to hold this
     rate ALONE -- that is why these are the only choices offered. */
  var MIXERS = [
    [44100, '44.1 kHz', '44.1k 曲库免 SRC（推荐）'],
    [48000, '48 kHz', '原厂默认'],
    [192000, '192 kHz', '高倍升采样'],
    [384000, '384 kHz', '拉满 · 高端机型']
  ];

  /* The vendor HiFi port ("hifi_playback") is the one USB audio ACTUALLY plays
     through on Qualcomm / OnePlus style ROMs -- deep_buffer just sits in standby.
     It ships [dynamic], so the policy pins it to the DAC maximum and resamples
     everything up.  Pinning it to the rate YOUR library uses makes that content
     bit-perfect; everything else is resampled UP (lossless band-limited
     interpolation), never DOWN (which would discard the ultrasonic band). */
  var HIFIS = [
    ['auto', 'auto', '原厂动态：跟随小尾巴最大率（全部上采样，无比特完美）'],
    [44100, '44.1 kHz', '44.1k 曲库'],
    [48000, '48 kHz', '48k 曲库'],
    [96000, '96 kHz', '96k 母带'],
    [176400, '176.4 kHz', '176.4k'],
    [192000, '192 kHz', '超清母带 / 臻品音质（推荐）'],
    [352800, '352.8 kHz', '352.8k'],
    [384000, '384 kHz', '384k 母带 · 高端机型']
  ];

  var PRESETS = {
    /* 自动识别：不预设任何参数，交给设备端读小尾巴上报的能力后自己决定 */
    'auto': { auto: true, label: '自动识别' },
    '384k': { mixer: 48000, max: 384000, bits: 32, label: '384 kHz 满血' },
    '192k': { mixer: 48000, max: 192000, bits: 24, label: '192 kHz 超清母带' },
    '96k':  { mixer: 48000, max: 96000,  bits: 24, label: '96 kHz 高清臻音' },
    '44k':  { mixer: 44100, max: 384000, bits: 32, label: '44.1 kHz 全局对齐' },
    '192mix': { mixer: 192000, max: 384000, bits: 32, label: '192 kHz 全局混音' },
    '384mix': { mixer: 384000, max: 384000, bits: 32, label: '384 kHz 全局混音' }
  };

  /* bit-depth ceiling.  16-bit is always kept as the baseline, so these are
     ceilings, not exclusive choices: 24 => 16+24, 32 => 16+24+32. */
  var BITS = [
    [16, '16-bit', '只保留 16bit'],
    [24, '24-bit', '16 + 24bit'],
    [32, '32-bit', '16 + 24 + 32bit，最宽松（默认）']
  ];

  /* 扬声器/听筒端口采样率档位。auto = 原厂不动；数字 = 钉死为该值。
     独立于全局混音率：混音器归 MIXERS 管，扬声器归这里管。 */
  var SPK_RATES = [
    ['auto', 'auto', '原厂行为（推荐）'],
    [44100, '44.1 kHz', '44.1k 曲库免 SRC'],
    [48000, '48 kHz', '48k 曲库免 SRC'],
    [96000, '96 kHz', '96k 母带'],
    [192000, '192 kHz', '192k 母带'],
    [384000, '384 kHz', '拉满 · 高端机型']
  ];
  var SPK_DSP = [
    [16, '16（关）', '不注入 enforce 属性（原厂 ADSP 位宽）'],
    [24, '24-bit', '强制 ADSP 24bit（apply 注入 / restore 清除）'],
    [32, '32-bit', '强制 ADSP 32bit（apply 注入 / restore 清除）']
  ];
  var SPK_BITS = [
    [16, '16-bit', '保持原厂（默认）'],
    [24, '24-bit', '16 + 24bit'],
    [32, '32-bit', '16 + 24 + 32bit']
  ];

  /* Smart PA loudspeaker gain tiers (tinymix control 23 on TFA9874-class
     devices).  0 = G_DEFAULT (factory, recommended); 1..6 = explicit +dB
     tiers that RAISE SPEAKER DRIVE POWER -- every click runs a two-step
     confirm on the device side as well (bin/hifi prints the warning). */
  var PA_GAINS = [
    [0, '出厂 0（推荐）'],
    [1, '+1dB'], [2, '+2dB'], [3, '+3dB'],
    [4, '+4dB'], [5, '+5dB'], [6, '+6dB']
  ];

  var state = {
    mod: null, mixer: 48000, max: 384000, bits: 32, hifi: 'auto',
    spk: 'auto', spkBits: 16, spkDsp: 16, bp: 0, dialect: '', sdk: '',
    paGain: null, paBoost: null,       /* smart PA knobs from `hifi json` */
    paConfirm: null,                   /* first click of the two-step confirm */
    restart: true, applied: false, enabled: 1,
    bridge: null,          /* which window object answered                   */
    form: null,            /* which call signature that object speaks        */
    last: null,            /* last raw result, for the self test             */
    bg: { slots: [], active: 0, opacity: 1 }
  };

  /* ------------------------------------------------- background image system
   * Six slots: three builtin presets (webroot/bg/bgN.jpg, shipped assets) and
   * three user slots whose dataURL bodies live in localStorage keys
   * hifi.bg.uc1..3 (one key per slot, each under the per-key quota).  Slot
   * metadata (names, active slot, opacity) lives in hifi.bg.meta.  active:-1
   * means the background is off.  opacity is the FOREGROUND PANEL opacity in
   * percent (0..100, default 50): it drives --fg-alpha, so with a background
   * active the cards/pills go translucent while text stays opaque.  Quality
   * policy: NO downsampling and no lossy transcoding by default -- the crop
   * is exported exactly as drawn (PNG lossless, or the original JPEG format
   * at quality 0.92); only when the export exceeds the storage budget do we
   * (1) retry as PNG, then (2) downscale once, and the user is told about
   * any scaling. */
  var BG_BUILTIN = [
    { key: 'bg1', name: '誓死效忠水月吉米' },
    { key: 'bg2', name: '誓死效忠水月雨' },
    { key: 'bg3', name: '誓死效忠天使吉米' }
  ];
  var BG_CUSTOM = ['uc1', 'uc2', 'uc3'];
  var BG_META_KEY = 'hifi.bg.meta';
  var BG_BUDGET = 2.5 * 1024 * 1024;   /* max dataURL chars per custom slot */
  var BG_JPEG_QUALITY = 0.92;

  function bgStore() {
    try { return window.localStorage; } catch (e) { return null; }
  }

  function bgLoadMeta() {
    var st = bgStore();
    if (!st) return null;
    try {
      var v = JSON.parse(st.getItem(BG_META_KEY) || 'null');
      return (v && typeof v === 'object') ? v : null;
    } catch (e) { return null; }
  }

  function bgSaveMeta() {
    var st = bgStore();
    if (!st) return;
    var names = {};
    state.bg.slots.forEach(function (s) { names[s.key] = s.name; });
    try {
      st.setItem(BG_META_KEY, JSON.stringify({
        active: state.bg.active, opacity: state.bg.opacity, names: names
      }));
    } catch (e) { /* quota hit on a tiny key: nothing sensible to do */ }
  }

  function bgLoadCustom(key) {
    var st = bgStore();
    if (!st) return null;
    try { return st.getItem('hifi.bg.' + key) || null; } catch (e) { return null; }
  }

  function bgSlotUrl(slot) {
    if (state.bg.active < 0) return null;
    var s = state.bg.slots[state.bg.active];
    if (!s) return null;
    return s.custom ? bgLoadCustom(s.key) : ('bg/' + s.key + '.jpg');
  }

  /* apply the current slot to the body css variables (fixed ::before layer).
     When the background is on, --fg-alpha carries the panel opacity percent
     from the slider (cards mix var(--panel) at that % over the image); off
     means full opacity, but the slider value itself is kept in meta. */
  function bgApply() {
    var b = document.body;
    if (!b) return;
    var root = document.documentElement;
    var url = bgSlotUrl();
    if (!url) {
      b.style.setProperty('--bg-img', 'none');
      b.style.setProperty('--fg-alpha', '100');
      b.classList.remove('has-bg');
      root.classList.remove('has-bg');
    } else {
      b.style.setProperty('--bg-img', 'url("' + url + '")');
      b.classList.add('has-bg');
      /* html keeps the class too: its var(--bg) background would otherwise
         paint over the fixed layer, and :has() is not safe on older WebViews */
      root.classList.add('has-bg');
      b.style.setProperty('--fg-alpha', String(state.bg.opacity));
    }
  }

  function bgInit() {
    state.bg.slots = [];
    BG_BUILTIN.forEach(function (b) {
      state.bg.slots.push({ name: b.name, custom: false, key: b.key });
    });
    BG_CUSTOM.forEach(function (k) {
      state.bg.slots.push({ name: '', custom: true, key: k });
    });
    var meta = bgLoadMeta();
    if (meta) {
      state.bg.active = Number(meta.active) | 0;
      if (state.bg.active < -1 || state.bg.active >= state.bg.slots.length) state.bg.active = 0;
      /* opacity is the PANEL percent 0..100 (default 50).  Older drafts of
         this feature stored a background opacity 0..1 -- map 0/1 to 100 so
         those users do not end up with an invisible panel. */
      var op = Number(meta.opacity);
      if (isNaN(op)) op = 50;
      if (op === 0 || op === 1) op = 100;
      state.bg.opacity = Math.min(100, Math.max(0, Math.round(op)));
      var names = meta.names || {};
      state.bg.slots.forEach(function (s) {
        if (typeof names[s.key] === 'string' && names[s.key]) s.name = names[s.key];
      });
    } else {
      state.bg.active = 0;
      state.bg.opacity = 50;
    }
    bgApply();
    bgRender();
  }

  function bgRender() {
    var host = $('pillBg');
    if (!host) return;
    host.innerHTML = '';
    var st = bgStore();
    state.bg.slots.forEach(function (s, i) {
      var el = document.createElement('button');
      var has = s.custom ? !!bgLoadCustom(s.key) : true;
      var label = s.custom ? (has ? (s.name || ('自定义 ' + (i - 2))) : '空槽 ' + (i - 2)) : s.name;
      el.className = 'pill' + (state.bg.active === i ? ' sel' : '');
      el.textContent = label;
      var em = document.createElement('em');
      em.textContent = s.custom
        ? (has ? ('自定义 · ' + Math.round(bgLoadCustom(s.key).length / 1024) + 'KB') : '点编辑上传')
        : '内置预设';
      el.appendChild(em);
      el.dataset.slot = String(i);
      host.appendChild(el);
    });
    var ed = document.createElement('button');
    ed.className = 'pill';
    ed.textContent = '编辑';
    var edm = document.createElement('em');
    edm.textContent = '命名 / 上传 / 裁切';
    ed.appendChild(edm);
    ed.dataset.slot = 'edit';
    host.appendChild(ed);
    var cur = state.bg.active >= 0 ? state.bg.slots[state.bg.active] : null;
    var line = $('bgState');
    if (line) {
      if (!cur) {
        line.textContent = '背景已关闭；点任意预设重新开启。';
      } else if (!cur.custom) {
        line.textContent = '当前：「' + cur.name + '」（内置）；点「编辑」可重命名。';
      } else {
        var has = bgLoadCustom(cur.key);
        line.textContent = has
          ? '当前：「' + (cur.name || cur.key) + '」（自定义 · ' + Math.round(has.length / 1024) + 'KB）'
          : '当前：空槽 ' + cur.key + '；选一张图保存即可使用。';
      }
    }
    /* keep the editor name input in sync with the selected slot */
    var inp = $('bgName');
    if (inp && cur) inp.value = cur.name;
    var ov = $('bgOpacityVal');
    if (ov) ov.textContent = state.bg.opacity + '%';
    var os = $('bgOpacity');
    if (os) os.value = String(state.bg.opacity);
    if (st === null && line) {
      line.textContent += '（当前环境无 localStorage，背景设置不会被记住）';
    }
  }

  /* like bgRender, but deferred: the pill host is re-rendered from inside a
     click on one of its own pills.  The document-level pill delegate runs
     LATER in the same bubble and reads el.parentNode -- replacing the host
     children synchronously detaches that pill and makes the delegate throw. */
  function bgRenderSoon() { setTimeout(bgRender, 0); }

  function bgSelect(i) {
    state.bg.active = i;
    bgApply();
    bgSaveMeta();
    bgRenderSoon();
  }

  /* ------------------------------------------------ crop editor (canvas 2D)
   * Album-style WYSIWYG crop: the FRAME is fixed at the chosen aspect ratio
   * and the USER MOVES/SCALES THE IMAGE inside it.  Everything outside the
   * frame is dimmed by a mask, and ONLY the frame's pixels get exported, so
   * the saved image is exactly the final background.  Constraints: the image
   * can never scale below "cover the frame" and never drag its edges inside
   * the frame -- no holes, always covered.  Coordinates use a fixed logical
   * resolution (canvas backing store scaled by devicePixelRatio for
   * sharpness); the export covers exactly the frame rect. */
  var BG_RATIOS = [
    ['9:19.5', '9:19.5（全面屏 · 推荐）', 9 / 19.5],
    ['9:16', '9:16（传统）', 9 / 16],
    ['3:4', '3:4', 3 / 4],
    ['1:1', '1:1', 1],
    ['fit', '自适应本机', 0]                  /* 0 = measured from viewport */
  ];
  var BG_MAX_ZOOM = 5;
  var bgEdit = {
    img: null, jpeg: false, ratio: '9:19.5',
    /* frame rect in canvas logical px; canvas logical size == frame size +
       a small dimmed margin so the "outside" is visible */
    fw: 0, fh: 0, fx: 0, fy: 0,
    k: 1,                 /* image->canvas scale (image px -> logical px)  */
    dx: 0, dy: 0,         /* image top-left in logical px                  */
    lastX: 0, lastY: 0, pinch: 0, dpr: 1
  };

  function bgRatioValue() {
    for (var i = 0; i < BG_RATIOS.length; i++) {
      if (BG_RATIOS[i][0] === bgEdit.ratio) {
        return BG_RATIOS[i][2] || (window.innerWidth / Math.max(1, window.innerHeight));
      }
    }
    return 9 / 19.5;
  }

  /* (re)size the canvas: the FRAME fills the width at the chosen ratio, with
     a slim dimmed margin around it.  Backing store is scaled by dpr. */
  function bgCanvasSize() {
    var c = $('bgCanvas');
    var cw = (c.parentNode.clientWidth || c.clientWidth || 320) - 2;
    var m = Math.max(6, Math.round(cw * 0.03));       /* dimmed margin */
    var fw = Math.max(120, cw - m * 2);
    var fh = Math.max(120, Math.round(fw / bgRatioValue()));
    var dpr = Math.min(3, Math.max(1, window.devicePixelRatio || 1));
    c.style.height = (fh + m * 2) + 'px';
    c.width = Math.round((fw + m * 2) * dpr);
    c.height = Math.round((fh + m * 2) * dpr);
    bgEdit.fw = fw; bgEdit.fh = fh; bgEdit.fx = m; bgEdit.fy = m;
    bgEdit.dpr = dpr;
    return { w: fw + m * 2, h: fh + m * 2 };
  }

  /* smallest k that still covers the frame */
  function bgMinScale() {
    var img = bgEdit.img;
    if (!img) return 0.01;
    return Math.max(bgEdit.fw / img.width, bgEdit.fh / img.height);
  }

  /* clamp k to [cover, 5x cover] and dx/dy so the image always covers
     the frame (no hole anywhere inside the frame).  Per axis the legal pan
     interval is [fx, fx+fw-W*k] when the image is wider than the frame and
     the mirror image of it when narrower -- order lo/hi explicitly, a naive
     min(fx+fw-W*k, max(fx, dx)) collapses to the lower bound whenever the
     image overflows the frame and pins the picture to the bottom-right. */
  function bgClamp() {
    var kmin = bgMinScale();
    bgEdit.k = Math.min(kmin * BG_MAX_ZOOM, Math.max(kmin, bgEdit.k));
    function axis(d, f, span, size) {
      var lo = Math.min(f, f + span - size), hi = Math.max(f, f + span - size);
      return Math.min(hi, Math.max(lo, d));
    }
    bgEdit.dx = axis(bgEdit.dx, bgEdit.fx, bgEdit.fw, bgEdit.img.width * bgEdit.k);
    bgEdit.dy = axis(bgEdit.dy, bgEdit.fy, bgEdit.fh, bgEdit.img.height * bgEdit.k);
  }

  function bgCanvasOpen(file) {
    var reader = new FileReader();
    reader.onload = function () {
      var img = new Image();
      img.onload = function () {
        bgCanvasSize();
        bgEdit.img = img;
        bgEdit.jpeg = /image\/jpe?g/i.test(String(file.type || ''));
        /* initial: cover the frame, centred */
        bgEdit.k = bgMinScale();
        bgEdit.dx = bgEdit.fx + (bgEdit.fw - img.width * bgEdit.k) / 2;
        bgEdit.dy = bgEdit.fy + (bgEdit.fh - img.height * bgEdit.k) / 2;
        bgCanvasDraw();
        $('bgEditor').hidden = false;
        bgMsg('已载入 ' + img.width + '×' + img.height + '；框内即保存后的背景，拖动 / 双指调整，点「保存此区域」。');
      };
      img.onerror = function () { bgMsg('图片读取失败，请换一张试试。'); };
      img.src = reader.result;
    };
    reader.readAsDataURL(file);
  }

  function bgCanvasDraw() {
    var c = $('bgCanvas');
    var ctx = c.getContext('2d');
    var d = bgEdit.dpr || 1;
    ctx.setTransform(d, 0, 0, d, 0, 0);
    ctx.clearRect(0, 0, c.width / d, c.height / d);
    if (!bgEdit.img) return;
    bgClamp();
    var lw = c.width / d, lh = c.height / d;
    /* dimmed backdrop, then the image, then a darker mask with the frame
       cut out -- the frame interior shows the untouched picture (WYSIWYG) */
    ctx.fillStyle = 'rgba(0,0,0,.45)';
    ctx.fillRect(0, 0, lw, lh);
    ctx.drawImage(bgEdit.img, bgEdit.dx, bgEdit.dy,
                  bgEdit.img.width * bgEdit.k, bgEdit.img.height * bgEdit.k);
    ctx.fillStyle = 'rgba(0,0,0,.5)';
    ctx.fillRect(0, 0, lw, bgEdit.fy);
    ctx.fillRect(0, bgEdit.fy + bgEdit.fh, lw, lh - bgEdit.fy - bgEdit.fh);
    ctx.fillRect(0, bgEdit.fy, bgEdit.fx, bgEdit.fh);
    ctx.fillRect(bgEdit.fx + bgEdit.fw, bgEdit.fy, lw - bgEdit.fx - bgEdit.fw, bgEdit.fh);
    /* frame border so the crop area is unmistakable */
    ctx.strokeStyle = 'rgba(255,255,255,.9)';
    ctx.lineWidth = 2;
    ctx.strokeRect(bgEdit.fx + 1, bgEdit.fy + 1, bgEdit.fw - 2, bgEdit.fh - 2);
  }

  /* zoom keeping the point (px,py) -- in logical px -- visually fixed */
  function bgScaleAt(factor, px, py) {
    if (!bgEdit.img) return;
    var k0 = bgEdit.k;
    var kmin = bgMinScale();
    var k1 = Math.min(kmin * BG_MAX_ZOOM, Math.max(kmin, k0 * factor));
    if (k1 === k0) return;
    px = (px === undefined) ? bgEdit.fx + bgEdit.fw / 2 : px;
    py = (py === undefined) ? bgEdit.fy + bgEdit.fh / 2 : py;
    bgEdit.dx = px - (px - bgEdit.dx) * (k1 / k0);
    bgEdit.dy = py - (py - bgEdit.dy) * (k1 / k0);
    bgEdit.k = k1;
    bgClamp();
    bgCanvasDraw();
  }

  /* switch the frame ratio: resize, re-cover and redraw.  The pill host is
     re-rendered deferred -- this click is still bubbling to the document
     delegate which reads el.parentNode (same trap as pillBg). */
  function bgSetRatio(key) {
    bgEdit.ratio = key;
    setTimeout(bgRenderRatio, 0);
    if (bgEdit.img) {
      bgCanvasSize();
      bgEdit.k = bgMinScale();
      bgEdit.dx = bgEdit.fx + (bgEdit.fw - bgEdit.img.width * bgEdit.k) / 2;
      bgEdit.dy = bgEdit.fy + (bgEdit.fh - bgEdit.img.height * bgEdit.k) / 2;
      bgCanvasDraw();
    }
  }

  function bgRenderRatio() {
    var host = $('bgRatio');
    if (!host) return;
    host.innerHTML = '';
    BG_RATIOS.forEach(function (r) {
      var el = document.createElement('button');
      el.className = 'pill' + (bgEdit.ratio === r[0] ? ' sel' : '');
      el.textContent = r[1];
      el.dataset.ratio = r[0];
      host.appendChild(el);
    });
  }

  /* export ONLY the frame rect at full backing-store resolution: draw the
     image, offset by -frame, into a fresh canvas -- the mask never enters
     the export.  PNG lossless by default, JPEG kept for jpeg sources. */
  function bgExport() {
    var img = bgEdit.img;
    var d = bgEdit.dpr || 1;
    var off = document.createElement('canvas');
    off.width = Math.round(bgEdit.fw * d);
    off.height = Math.round(bgEdit.fh * d);
    var octx = off.getContext('2d');
    octx.scale(d, d);
    octx.drawImage(img, bgEdit.dx - bgEdit.fx, bgEdit.dy - bgEdit.fy,
                   img.width * bgEdit.k, img.height * bgEdit.k);
    return bgEdit.jpeg ? off.toDataURL('image/jpeg', BG_JPEG_QUALITY)
                       : off.toDataURL('image/png');
  }

  /* fit the frame export into w*h (single lossless resample) -- last resort
     over budget; the frame ratio is preserved */
  function bgExportScaled(w, h) {
    var img = bgEdit.img;
    var d = bgEdit.dpr || 1;
    var off = document.createElement('canvas');
    off.width = w; off.height = h;
    off.getContext('2d').drawImage(img, (bgEdit.dx - bgEdit.fx) * (w / (bgEdit.fw * d)),
                                   (bgEdit.dy - bgEdit.fy) * (h / (bgEdit.fh * d)),
                                   img.width * bgEdit.k * (w / (bgEdit.fw * d)),
                                   img.height * bgEdit.k * (h / (bgEdit.fh * d)));
    return bgEdit.jpeg ? off.toDataURL('image/jpeg', BG_JPEG_QUALITY)
                       : off.toDataURL('image/png');
  }

  function bgSave() {
    if (!bgEdit.img) { bgMsg('先点「选图」再保存。'); return; }
    var slotIdx = bgPickTarget();
    if (slotIdx < 0) { bgMsg('没有可用槽位。'); return; }
    var slot = state.bg.slots[slotIdx];
    var data = bgExport();
    var over = data.length - BG_BUDGET;
    if (over > 0) {
      /* 1st retry: PNG lossless (only relevant for jpeg sources).  2nd and
         last resort: ONE downscale of the frame export -- and we say so,
         with the exact size.  The frame ratio is never changed. */
      if (bgEdit.jpeg) {
        var d = bgEdit.dpr || 1;
        data = bgExportScaled(Math.round(bgEdit.fw * d), Math.round(bgEdit.fh * d));
      }
      if (data.length > BG_BUDGET) {
        var d2 = bgEdit.dpr || 1;
        var k = Math.sqrt(BG_BUDGET / data.length) * 0.98;
        var w = Math.max(1, Math.round(bgEdit.fw * d2 * k));
        var h = Math.max(1, Math.round(bgEdit.fh * d2 * k));
        data = bgExportScaled(w, h);
        if (data.length > BG_BUDGET) {
          bgMsg('保存被拒：这张图导出后约 ' + bgKb(data.length) + 'KB，超过单张 2.5MB 预算 ' +
                bgKb(data.length - BG_BUDGET) + 'KB，即使缩到 ' + w + '×' + h +
                ' 也放不下。请裁小一点再保存。');
          return;
        }
        bgMsg('已缩放到 ' + w + '×' + h + ' 以适配存储（缩小 ' +
              Math.round((1 - k) * 100) + '%）——重选图裁更小可避免缩放。');
      }
    }
    var st = bgStore();
    if (!st) { bgMsg('当前环境不支持 localStorage，无法保存自定义图。'); return; }
    /* overwrite confirm: total size across the three custom slots matters */
    var total = 0;
    BG_CUSTOM.forEach(function (k2) { total += (bgLoadCustom(k2) || '').length; });
    if ((bgLoadCustom(slot.key) || '').length > 0) {
      if (!window.confirm('槽位「' + (slot.name || slot.key) + '」已有图片（3 个自定义槽共 ' +
          bgKb(total) + 'KB，单张上限 2.5MB）。覆盖它？')) return;
    }
    try {
      st.setItem('hifi.bg.' + slot.key, data);
    } catch (e) {
      bgMsg('保存被拒：浏览器存储写入失败（quota）。这张图约 ' + bgKb(data.length) +
            'KB，请裁小一点或清掉其他自定义槽再试。');
      return;
    }
    if (!slot.name) slot.name = '自定义图 ' + (slotIdx - 2);
    bgSaveMeta();
    bgRender();
    bgMsg('已保存到「' + slot.name + '」（' + bgKb(data.length) + 'KB）。');
  }

  function bgPickTarget() {
    /* prefer the active slot if it is custom, else first empty, else uc1 */
    var cur = state.bg.active >= 0 ? state.bg.slots[state.bg.active] : null;
    if (cur && cur.custom) return state.bg.active;
    for (var i = 3; i < 6; i++) {
      if (!bgLoadCustom(state.bg.slots[i].key)) return i;
    }
    return state.bg.active >= 3 ? state.bg.active : 3;
  }

  function bgClear() {
    var cur = state.bg.active >= 0 ? state.bg.slots[state.bg.active] : null;
    if (!cur || !cur.custom) { bgMsg('先在预设里选中一个自定义槽（空槽 1..3）再清空。'); return; }
    var st = bgStore();
    if (st) {
      try { st.removeItem('hifi.bg.' + cur.key); } catch (e) { /* ignore */ }
    }
    cur.name = '';
    bgSaveMeta();
    bgRender();
    bgMsg('已清空槽 ' + cur.key + '。');
  }

  function bgRename() {
    if (state.bg.active < 0) { bgMsg('先选中一个槽再重命名。'); return; }
    var slot = state.bg.slots[state.bg.active];
    var inp = $('bgName');
    var name = String(inp.value || '').trim();
    if (!name) { bgMsg('名字不能为空。'); return; }
    slot.name = name;
    bgSaveMeta();
    bgRender();
    bgMsg('已把当前槽重命名为「' + name + '」。');
  }

  function bgKb(n) { return Math.round(n / 1024); }

  function bgMsg(t) {
    var ed = $('bgEditor');
    if (ed && !ed.hidden) {
      var line = $('bgState');
      if (line) line.textContent = t;
    } else {
      toast(t);
    }
  }

  function bgBind() {
    var host = $('pillBg');
    if (!host) return;
    host.addEventListener('click', function (ev) {
      var el = ev.target.closest ? ev.target.closest('.pill') : null;
      if (!el) return;
      if (el.dataset.slot === 'edit') {
        var ed = $('bgEditor');
        ed.hidden = !ed.hidden;
        if (!ed.hidden) {
          bgRenderRatio();
          var c = $('bgCanvas');
          if (!bgEdit.img) { bgCanvasSize(); bgCanvasDraw(); }
          else { bgCanvasSize(); bgCanvasDraw(); }
        }
        bgRenderSoon();
        return;
      }
      bgSelect(Number(el.dataset.slot));
    });
    $('btnBgOff').addEventListener('click', function () {
      state.bg.active = -1;
      bgApply();
      bgSaveMeta();
      bgRenderSoon();
    });
    $('btnBgPick').addEventListener('click', function () { $('bgFile').click(); });
    $('bgFile').addEventListener('change', function () {
      var f = this.files && this.files[0];
      this.value = '';
      if (f) bgCanvasOpen(f);
    });
    $('btnBgSave').addEventListener('click', bgSave);
    $('btnBgClear').addEventListener('click', bgClear);
    $('btnBgRename').addEventListener('click', bgRename);
    $('bgName').addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); bgRename(); }
    });
    /* panel opacity slider: applies at once and persists in the same meta key
       (opacity = foreground panel percent, 0..100) */
    $('bgOpacity').addEventListener('input', function () {
      state.bg.opacity = Math.min(100, Math.max(0, Math.round(Number(this.value) || 0)));
      var ov = $('bgOpacityVal');
      if (ov) ov.textContent = state.bg.opacity + '%';
      if (state.bg.active >= 0) {
        document.body.style.setProperty('--fg-alpha', String(state.bg.opacity));
      }
    });
    $('bgOpacity').addEventListener('change', function () {
      state.bg.opacity = Math.min(100, Math.max(0, Math.round(Number(this.value) || 0)));
      bgSaveMeta();
      bgApply();
    });

    var c = $('bgCanvas');
    /* ratio pills live in the editor; a click re-frames the crop */
    var rhost = $('bgRatio');
    if (rhost) {
      rhost.addEventListener('click', function (ev) {
        var el = ev.target.closest ? ev.target.closest('.pill') : null;
        if (!el || !el.dataset.ratio) return;
        bgSetRatio(el.dataset.ratio);
      });
    }
    /* album-style gestures inside the fixed frame.  Pointer coords are
       converted to canvas logical px (client -> rect -> minus margin,
       backing store is dpr-scaled but drawing is in logical px). */
    function bgPt(e) {
      var r = c.getBoundingClientRect();
      return {
        x: (e.clientX - r.left) * (c.width / (r.width * (bgEdit.dpr || 1))) - 0,
        y: (e.clientY - r.top) * (c.height / (r.height * (bgEdit.dpr || 1))) - 0
      };
    }
    /* one-finger drag / two-finger pinch (anchored at the pinch centre) */
    c.addEventListener('touchstart', function (e) {
      if (e.touches.length === 1) {
        var p = bgPt(e.touches[0]);
        bgEdit.lastX = p.x; bgEdit.lastY = p.y;
      } else if (e.touches.length === 2) {
        var p0 = bgPt(e.touches[0]), p1 = bgPt(e.touches[1]);
        bgEdit.pinch = Math.hypot(p0.x - p1.x, p0.y - p1.y);
        bgEdit.pinchX = (p0.x + p1.x) / 2; bgEdit.pinchY = (p0.y + p1.y) / 2;
      }
      e.preventDefault();
    }, { passive: false });
    c.addEventListener('touchmove', function (e) {
      if (e.touches.length === 1 && bgEdit.img) {
        var p = bgPt(e.touches[0]);
        bgEdit.dx += p.x - bgEdit.lastX;
        bgEdit.dy += p.y - bgEdit.lastY;
        bgEdit.lastX = p.x; bgEdit.lastY = p.y;
        bgCanvasDraw();
      } else if (e.touches.length === 2 && bgEdit.pinch > 0 && bgEdit.img) {
        var p0 = bgPt(e.touches[0]), p1 = bgPt(e.touches[1]);
        var d = Math.hypot(p0.x - p1.x, p0.y - p1.y);
        bgScaleAt(d / bgEdit.pinch, bgEdit.pinchX, bgEdit.pinchY);
        bgEdit.pinch = d;
        bgEdit.pinchX = (p0.x + p1.x) / 2; bgEdit.pinchY = (p0.y + p1.y) / 2;
      }
      e.preventDefault();
    }, { passive: false });
    c.addEventListener('touchend', function (e) {
      bgEdit.pinch = 0;
      /* a finger was lifted during a pinch: re-anchor the one-finger drag to
         whichever touch remains, else the next move jumps from stale coords */
      if (e.touches.length === 1) {
        var p = bgPt(e.touches[0]);
        bgEdit.lastX = p.x; bgEdit.lastY = p.y;
      }
    });
    /* mouse: drag with the button held, wheel zooms at the cursor */
    c.addEventListener('mousedown', function (e) {
      var p = bgPt(e);
      bgEdit.lastX = p.x; bgEdit.lastY = p.y;
      bgEdit.drag = true;
      e.preventDefault();
    });
    window.addEventListener('mousemove', function (e) {
      if (!bgEdit.drag || !bgEdit.img) return;
      var p = bgPt(e);
      bgEdit.dx += p.x - bgEdit.lastX;
      bgEdit.dy += p.y - bgEdit.lastY;
      bgEdit.lastX = p.x; bgEdit.lastY = p.y;
      bgCanvasDraw();
    });
    window.addEventListener('mouseup', function () { bgEdit.drag = false; });
    c.addEventListener('wheel', function (e) {
      if (!bgEdit.img) return;
      e.preventDefault();
      var p = bgPt(e);
      bgScaleAt(e.deltaY < 0 ? 1.1 : 1 / 1.1, p.x, p.y);
    }, { passive: false });
  }

  var $ = function (id) { return document.getElementById(id); };

  /* ------------------------------------------------------------ root bridge */
  var BRIDGES = ['ksu', 'kernelsu', 'KernelSU', 'KsuWebUI',
                 'apatch', 'APatch', 'APatchWebUI'];

  function bridge() {
    for (var i = 0; i < BRIDGES.length; i++) {
      var b = window[BRIDGES[i]];
      if (b && typeof b.exec === 'function') { state.bridge = BRIDGES[i]; return b; }
    }
    return null;
  }

  /* the signatures we are willing to speak, most likely first.
     name3-json is the official KernelSU contract and is expected to win. */
  var FORMS = ['name3-json', 'fn3-json', 'fn2', 'obj3', 'sync1'];

  var cbSeq = 0;

  /* Run one command through one call form.
     Resolves with {errno,stdout,stderr}, or with null when the form produced
     no result at all (wrong signature for this manager).                     */
  function tryForm(b, form, cmd, grace) {
    return new Promise(function (resolve) {
      var settled = false;
      var cbName = 'hifisrc_cb_' + (++cbSeq);
      var timer = null;

      function finish(v) {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        try { delete window[cbName]; } catch (e) { /* ignore */ }
        resolve(v);
      }
      /* the native bridge invokes window[cbName](errno, stdout, stderr) */
      window[cbName] = function (errno, out, err) {
        finish({
          errno: Number(errno) || 0,
          stdout: out == null ? '' : String(out),
          stderr: err == null ? '' : String(err)
        });
      };
      function done(errno, out, err) { window[cbName](errno, out, err); }

      var r;
      try {
        if (form === 'name3-json')      r = b.exec(cmd, '{"cwd":"/"}', cbName);
        else if (form === 'fn3-json')   r = b.exec(cmd, '{"cwd":"/"}', done);
        else if (form === 'fn2')        r = b.exec(cmd, done);
        else if (form === 'obj3')       r = b.exec(cmd, { cwd: '/' }, done);
        else                            r = b.exec(cmd);
      } catch (e) {
        finish(null);                       /* signature rejected outright */
        return;
      }

      /* some managers answer synchronously or with a promise instead */
      if (r && typeof r.then === 'function') {
        r.then(function (v) {
          if (typeof v === 'string') done(0, v, '');
          else done(v && v.errno, v && v.stdout, v && v.stderr);
        })['catch'](function (e) { done(-1, '', String(e)); });
        return;
      }
      if (typeof r === 'string') { done(0, r, ''); return; }
      if (r && typeof r === 'object' && 'errno' in r) { done(r.errno, r.stdout, r.stderr); return; }

      /* undefined -> this form is asynchronous.  If the native side is not
         actually going to call back, we find out here instead of hanging. */
      timer = setTimeout(function () { finish(null); }, grace);
    });
  }

  var negotiation = null;

  function negotiate(b) {
    if (negotiation) return negotiation;
    negotiation = (function () {
      var i = 0;
      function next() {
        if (i >= FORMS.length) throw new Error('ROOT_BRIDGE_NO_RESULT');
        var f = FORMS[i++];
        return tryForm(b, f, 'id -u', PROBE_GRACE).then(function (r) {
          if (!r) return next();
          state.form = f;
          state.probe = r;
          return f;
        });
      }
      return Promise.resolve().then(next);
    })();
    negotiation['catch'](function () { negotiation = null; });
    return negotiation;
  }

  function sh(cmd, depth) {
    depth = depth || 0;
    var b = bridge();
    if (!b) return Promise.reject(new Error('ROOT_BRIDGE_MISSING'));
    return Promise.resolve(state.form || negotiate(b))
      .then(function (form) { return tryForm(b, form, cmd, CMD_GRACE); })
      .then(function (r) {
        if (!r) {
          /* a form that worked before went quiet - renegotiate exactly once,
             then report the truth instead of inventing a bogus cause */
          state.form = null;
          negotiation = null;
          if (depth === 0) return sh(cmd, 1);
          throw new Error('ROOT_BRIDGE_NO_RESULT');
        }
        state.last = { cmd: cmd, form: state.form, errno: r.errno,
                       stdout: r.stdout, stderr: r.stderr };
        return r;
      });
  }

  function q(p) { return "'" + String(p).replace(/'/g, "'\\''") + "'"; }

  /* ------------------------------------------------------------------- ui */
  function toast(msg, ms) {
    var t = document.querySelector('.toast');
    if (!t) {
      t = document.createElement('div');
      t.className = 'toast';
      document.body.appendChild(t);
    }
    t.textContent = msg;
    t.classList.add('show');
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.classList.remove('show'); }, ms || 2200);
  }

  function banner(msg, isErr) {
    var el = $('banner');
    if (!el) return;
    if (!msg) { el.classList.add('hidden'); return; }
    el.textContent = msg;
    el.classList.toggle('err', !!isErr);
    el.classList.remove('hidden');
  }

  function fmtHz(v) {
    if (!v) return '—';
    var n = Number(v);
    if (!isFinite(n) || n <= 0) return '—';
    return (n % 1000 === 0 ? n / 1000 : (n / 1000).toFixed(1)) + ' kHz';
  }

  function esc(t) {
    return String(t).replace(/[&<>"]/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c];
    });
  }

  function clip(s, n) {
    s = String(s == null ? '' : s);
    return s.length > n ? s.slice(0, n) + ' …(+' + (s.length - n) + 'B)' : s;
  }

  function currentPreset() {
    if (Number(state.max) === 384000 && Number(state.mixer) === 384000) return '384mix';
    if (Number(state.max) === 384000 && Number(state.mixer) === 192000) return '192mix';
    if (Number(state.max) === 384000 && Number(state.mixer) === 44100) return '44k';
    if (Number(state.max) === 384000 && Number(state.mixer) === 48000) return '384k';
    if (Number(state.max) === 192000 && Number(state.mixer) === 48000) return '192k';
    if (Number(state.max) === 96000 && Number(state.mixer) === 48000) return '96k';
    return null;
  }

  function renderPills() {
    var host = $('pillMax');
    host.innerHTML = '';
    RATES.forEach(function (r) {
      var b = document.createElement('button');
      b.className = 'pill' + (Number(state.max) === r[0] ? ' sel' : '');
      b.dataset.v = r[0];
      b.textContent = r[1];
      if (r[0] === 96000) b.title = '高清臻音 · 96 kHz / 24-bit';
      if (r[0] === 384000) b.title = 'CX31993 / 支持 384k 的小尾巴';
      host.appendChild(b);
    });
    var mh = $('pillMixer');
    if (mh) {
      mh.innerHTML = '';
      MIXERS.forEach(function (m) {
        var el = document.createElement('button');
        el.className = 'pill' + (Number(state.mixer) === m[0] ? ' sel' : '');
        el.dataset.v = m[0];
        el.textContent = m[1];
        var em = document.createElement('em');
        em.textContent = m[2];
        el.appendChild(em);
        mh.appendChild(el);
      });
    }
    var ph = $('pillHifi');
    if (ph) {
      ph.innerHTML = '';
      HIFIS.forEach(function (m) {
        var el = document.createElement('button');
        el.className = 'pill' + (String(state.hifi) === String(m[0]) ? ' sel' : '');
        el.dataset.h = m[0];
        el.textContent = m[1];
        var em = document.createElement('em');
        em.textContent = m[2];
        el.appendChild(em);
        ph.appendChild(el);
      });
    }
    var cur = currentPreset();
    Array.prototype.forEach.call($('pillPreset').children, function (b) {
      b.classList.toggle('sel', b.dataset.p === cur);
    });
    $('btnRestart').setAttribute('aria-checked', state.restart ? 'true' : 'false');
  }

  function renderBits() {
    var host = $('pillBits');
    if (!host) return;
    host.innerHTML = '';
    BITS.forEach(function (b) {
      var el = document.createElement('button');
      el.className = 'pill' + (Number(state.bits) === b[0] ? ' sel' : '');
      el.dataset.b = b[0];
      el.textContent = b[1];
      el.title = b[2];
      host.appendChild(el);
    });
  }

  function renderSpk() {
    var host = $('pillSpk');
    if (!host) return;
    host.innerHTML = '';
    SPK_RATES.forEach(function (r) {
      var el = document.createElement('button');
      el.className = 'pill' + (String(state.spk) === String(r[0]) ? ' sel' : '');
      el.dataset.v = r[0];
      el.textContent = r[1];
      var em = document.createElement('em');
      em.textContent = r[2];
      el.appendChild(em);
      host.appendChild(el);
    });
  }

  function renderSpkDsp() {
    var host = $('pillSpkDsp');
    if (!host) return;
    host.innerHTML = '';
    SPK_DSP.forEach(function (b) {
      var el = document.createElement('button');
      el.className = 'pill' + (Number(state.spkDsp) === b[0] ? ' sel' : '');
      el.dataset.d = b[0];
      el.textContent = b[1];
      el.title = b[2];
      host.appendChild(el);
    });
  }

  function renderSpkBits() {
    var host = $('pillSpkBits');
    if (!host) return;
    host.innerHTML = '';
    SPK_BITS.forEach(function (b) {
      var el = document.createElement('button');
      el.className = 'pill' + (Number(state.spkBits) === b[0] ? ' sel' : '');
      el.dataset.b = b[0];
      el.textContent = b[1];
      el.title = b[2];
      host.appendChild(el);
    });
  }

  /* smart PA pills.  the selected tier comes from state.pa_gain, i.e. from
     the persisted CONFIG (json), never from a tinymix read -- the WebUI must
     not depend on root-only mixer control reads. */
  function renderPa() {
    var host = $('pillPa');
    if (!host) return;
    host.innerHTML = '';
    PA_GAINS.forEach(function (g) {
      var el = document.createElement('button');
      var cur = state.paGain === null ? 0 : Number(state.paGain);
      el.className = 'pill' + (cur === g[0] ? ' sel' : '');
      el.dataset.g = g[0];
      el.textContent = g[1];
      host.appendChild(el);
    });
    var st = $('paState');
    if (st) {
      if (state.paGain === null || state.paGain === undefined) {
        st.textContent = '当前：未配置（出厂 0 · 原厂功率）';
      } else if (Number(state.paGain) === 0) {
        st.textContent = '当前：出厂 0（原厂功率，最安全）';
      } else {
        st.textContent = '当前：+' + Number(state.paGain) +
          'dB（高于原厂功率，注意破音立即回出厂 0）';
      }
      if (state.paBoost !== null && state.paBoost !== undefined && Number(state.paBoost) !== 2) {
        st.textContent += '；boost ' + Number(state.paBoost) + '（非出厂满档 2，省电但削峰更早）';
      }
    }
  }

  /* BIT_PERFECT is gated by TWO independent conditions on the device side
     (bin/hifi do_apply + payload/patch_policy.awk, same rule in both):
       1. dialect == qti (the AIDL audio HAL);          [dialect is a string]
       2. Android 14+ (SDK >= 34).                      [sdk is a STRING]
     `hifi json` ships `sdk` as a quoted string, and it is simply absent /
     empty when getprop could not answer, so missing-ness is treated as
     "unknown" -- and the device refuses an unknown SDK.  Both conditions are
     therefore rendered separately: a user must never be told "it works" when
     the version alone will get the apply refused. */
  function bpSdkState() {
    if (state.sdk === undefined || state.sdk === null || state.sdk === '') return 'unknown';
    var n = parseInt(state.sdk, 10);
    if (isNaN(n)) return 'unknown';
    return n >= 34 ? 'ok' : 'old';
  }

  function renderBp() {
    var host = $('pillBp');
    if (!host) return;
    Array.prototype.forEach.call(host.children, function (el) {
      el.className = 'pill' + (Number(state.bp) === Number(el.dataset.bp) ? ' sel' : '');
    });
    var hint = $('bpDialect');
    if (hint) {
      if (Number(state.bp) === 1) {
        /* The branch order mirrors the DEVICE gate exactly -- dialect first,
           then the version inside the AIDL case (bin/hifi do_apply, and the
           END block of payload/patch_policy.awk).  Keeping that shape also
           keeps the copy honest: only a `qti` dialect may be told "your
           version is the problem", because an empty dialect means the probe
           could not classify the device at all (bin/hifi: "" = unknown). */
        var dia = state.dialect === 'qti' ? 'qti'
                : (state.dialect === 'aosp' ? 'aosp' : 'unknown');
        if (dia === 'aosp') {
          hint.textContent = '本机是 HIDL 方言：BIT_PERFECT 不受 Android 支持，应用会被拒绝（不会卡开机、不会死机，其余档位照常）。';
        } else if (dia === 'qti') {
          var sdk = bpSdkState();
          if (sdk === 'old') {
            hint.textContent = '本机是 AIDL 方言，但版本不足：BIT_PERFECT 需要 Android 14+（SDK 34+），本机 SDK ' +
              parseInt(state.sdk, 10) + '，应用会被拒绝（不改动任何文件，其余档位照常）。';
          } else if (sdk === 'unknown') {
            hint.textContent = '本机是 AIDL 方言，但读不到版本号（ro.build.version.sdk）：BIT_PERFECT 需要 Android 14+（SDK 34+），无法确认时会被拒绝（不改动任何文件，其余档位照常）。';
          } else {
            hint.textContent = '本机是 AIDL 方言且版本满足（SDK ' + parseInt(state.sdk, 10) +
              '）：声明可以生效，但需要播放器用 preferred mixer attributes API 请求（Android 14+）。';
          }
        } else {
          /* Dialect unknown: never claim AIDL or HIDL here.  State both
             conditions and hand the verdict to the device. */
          var tail = bpSdkState() === 'old'
            ? '本机 SDK ' + parseInt(state.sdk, 10) + '，低于要求的 34。'
            : (bpSdkState() === 'unknown'
                ? '本机读不到版本号（ro.build.version.sdk）。'
                : '本机版本满足，但方言不明。');
          hint.textContent = '探测不到本机方言：' + tail +
            'BIT_PERFECT 需要 AIDL 方言 + Android 14+（SDK 34+），应用时由设备端判定，任一不满足会被拒绝（不改动任何文件，其余档位照常）。';
        }
        hint.hidden = false;
      } else {
        hint.hidden = true;
      }
    }
  }

  /* self test: everything we need to diagnose a failure remotely */
  function renderDiag() {
    var el = $('diagBox');
    if (!el) return;
    var L = [];
    L.push('root 桥接   : ' + (state.bridge || '— 未找到'));
    L.push('调用形式    : ' + (state.form || '—') + '   [name3-json = exec(cmd, optsJson, cbName)]');
    L.push('模块目录    : ' + (state.mod || '— 未解析'));
    L.push('当前档位    : 混音 ' + fmtHz(state.mixer) + ' / 上限 ' + fmtHz(state.max) +
           ' / 位深 ' + state.bits + 'bit');
    if (state.last) {
      L.push('最后命令    : ' + state.last.cmd);
      L.push('  errno     : ' + state.last.errno);
      L.push('  stdout    : ' + (clip(state.last.stdout, 700) || '（空）'));
      L.push('  stderr    : ' + (clip(state.last.stderr, 700) || '（空）'));
    } else {
      L.push('最后命令    : — 还没有任何一条命令跑通');
    }
    el.textContent = L.join('\n');
  }

  function renderStatus(s) {
    state.mixer = Number(s.mixer_rate);
    state.max = Number(s.max_rate);
    state.hifi = s.hifi_rate || 'auto';
    state.bits = Number(s.bit_depth) || 32;
    state.spk = s.spk_rate || 'auto';
    state.spkBits = Number(s.spk_bits) || 16;
    state.spkDsp = Number(s.spk_dsp_bits) || 16;
    /* smart PA: null (json null / absent) = the config never touches the PA,
       i.e. factory 0.  Any number 0..6 is what the config will apply. */
    state.paGain = (s.pa_gain === undefined || s.pa_gain === null) ? null : Number(s.pa_gain);
    state.paBoost = (s.pa_boost === undefined || s.pa_boost === null) ? null : Number(s.pa_boost);
    state.paConfirm = null;
    state.bp = Number(s.bit_perfect) || 0;
    state.dialect = s.dialect || '';
    /* `hifi json` sends sdk as a STRING ("" when getprop had nothing to say);
       keep it verbatim -- bpSdkState() is the only place that interprets it. */
    state.sdk = (s.sdk === undefined || s.sdk === null) ? '' : String(s.sdk);
    state.restart = !(s.restart === 0 || s.restart === false);
    state.applied = !!s.applied;
    state.enabled = s.enabled === 0 ? 0 : 1;

    /* The version appears twice on the page (hero badge + footer).  Both are
       rendered from the same `hifi json` field, which bin/hifi reads from
       module.prop -> version=, so bumping the module version can never leave a
       stale number behind in the shipped HTML. */
    var verTxt = 'v' + (s.version || '?');
    $('badgeVersion').textContent = verTxt;
    var footVer = $('footVersion');
    if (footVer) footVer.textContent = verTxt;
    var badge = $('badgeApplied');
    if (s.enabled === 0) { badge.textContent = '已还原原厂'; badge.className = 'badge off'; }
    else if (s.applied) { badge.textContent = '补丁生效中'; badge.className = 'badge on'; }
    else { badge.textContent = '未生效'; badge.className = 'badge off'; }

    $('stApplied').textContent = s.applied ? '已挂载' : '未挂载';
    $('stMixer').textContent = fmtHz(s.mixer_rate);
    $('stMax').textContent = fmtHz(s.max_rate);
    var stHf = $('stHifi');
    if (stHf) stHf.textContent = (s.hifi_rate || 'auto') === 'auto'
      ? 'auto（跟随小尾巴最大率）' : fmtHz(s.hifi_rate) + '（锁定）';
    var stB = $('stBits');
    if (stB) stB.textContent = s.bit_depth ? (s.bit_depth + '-bit') : '—';
    var stS = $('stSpk');
    if (stS) stS.textContent = (s.spk_rate || 'auto') === 'auto'
      ? 'auto（原厂）' : fmtHz(s.spk_rate) + '（锁定）';
    var stSB = $('stSpkBits');
    if (stSB) stSB.textContent = state.spkBits + '-bit';
    var stDsp = $('stSpkDsp');
    if (stDsp) stDsp.textContent = Number(state.spkDsp) === 16
      ? '16（关）' : state.spkDsp + '-bit（强制）';
    $('stAudio').textContent = s.audioserver || '—';
    $('stDevice').textContent = (s.device || '—') + ' / SDK ' + (s.sdk || '—');
    var stF = $('stFiles');
    if (stF) {
      var ok = Number(s.applied_files || 0), all = Number(s.total_files || 0);
      stF.textContent = all ? (ok + ' / ' + all + ' 个文件') : '—';
    }
    var hOn = !(s.hal_enabled === 0 || s.hal_enabled === false);
    var hAll = Number(s.hal_files || 0), hOk = Number(s.hal_applied || 0);
    var stH = $('stHal');
    if (stH) {
      if (!hOn) stH.textContent = '已关闭';
      else if (!hAll) stH.textContent = '本机无此库';
      else stH.textContent = hOk + ' / ' + hAll + ' 个库';
    }
    $('stTarget').textContent = s.target || '未找到';
    $('logBox').textContent = (s.log_tail || '').replace(/\n$/, '') || '—';

    if (s.old_module) {
      banner('⚠ 检测到仍装着旧的一加 13 专用模块。两者会同时改写音频策略，建议先在管理器里卸载旧模块，再重启手机。', true);
    } else if (!state.applied) {
      banner('补丁当前未挂载，原厂策略正在生效。点「应用并生效」立即启用，或重启手机让模块开机自动生效。', false);
    } else if (hOn && hAll && !hOk) {
      banner('⚠ 策略层已生效，但 USB HAL 库（libalsautils）仍是原厂采样率表——' +
             '真正的硬件上限大多卡在这里（常见 96k）。请点「应用并生效」重试，或重启一次让开机流程重新挂载；' +
             '若连续两次都如此，请用「开始校验」或命令 hifi status 查看 HAL 层原因。', true);
    } else if (hOn && !hAll) {
      banner('本机没有 AOSP 的 USB HAL 库（可能是厂商自写 HAL），模块只对策略层生效——这是正常情况，无需处理。', false);
    } else if (s.dac_max && Number(s.dac_max) < Number(s.max_rate)) {
      banner('⚠ 检测到你的解码器上限只有 ' + fmtHz(s.dac_max) + '，但当前直通上限开到了 ' +
             fmtHz(s.max_rate) + '。上限高于设备能力可能导致无声，建议调低。', true);
    } else if (s.dac_max && Number(s.dac_max) > Number(s.max_rate)) {
      banner('检测到你的解码器最高支持 ' + fmtHz(s.dac_max) + '，当前上限只开到 ' + fmtHz(s.max_rate) + '。可以把它调高。', false);
    } else {
      banner('');
    }

    renderPills();
    renderBits();
    renderSpk();
    renderSpkBits();
    renderSpkDsp();
    renderPa();
    renderBp();
    renderDac(s);
    renderDiag();
  }

  function renderDac(s) {
    var box = $('dacBox');
    if (!s.dac_name) {
      box.innerHTML = '<p class="muted">未检测到 USB 音频设备。插上小尾巴后点击「重新检测」。</p>';
      return;
    }
    var html = '<div class="dname">' + esc(s.dac_name) + '</div>';
    html += '<div class="drow">芯片上报最高采样率：<b>' + fmtHz(s.dac_max) + '</b></div>';
    if (s.dac_formats) {
      html += '<div class="drow">芯片上报格式：<b>' + esc(s.dac_formats) + '</b>（S16_LE = 16bit，S24_3LE = 24bit，S32_LE = 32bit）</div>';
    }
    var cap = dacBits(s.dac_formats);
    if (state.max && s.dac_max && Number(state.max) > Number(s.dac_max)) {
      html += '<div class="drow">⚠ 当前直通上限高于解码器能力，可能出现无声，建议调低。</div>';
    }
    if (cap && state.bits && Number(state.bits) > cap) {
      html += '<div class="drow">⚠ 当前位深 ' + state.bits + 'bit 高于解码器能力（' + cap +
              'bit）—— 也可能无声，建议把位深降到 ' + cap + 'bit。</div>';
    }
    if (Number(s.dac_max) >= 96000) {
      html += '<div class="drow">提示：96 kHz 与 192 kHz 档位始终保留，可用于兼容性排查。</div>';
    }
    box.innerHTML = html;
  }

  /* highest bit depth the DAC advertises, read from its ALSA format strings */
  function dacBits(formats) {
    var f = String(formats || '').toUpperCase();
    var m = 0;
    if (f.indexOf('S16') !== -1) m = Math.max(m, 16);
    if (f.indexOf('S24') !== -1) m = Math.max(m, 24);
    if (f.indexOf('S32') !== -1) m = Math.max(m, 32);
    return m;
  }

  function busy(on, label) {
    ['btnApply', 'btnReset', 'btnDac', 'btnRefresh', 'btnDiag', 'btnDoctor', 'btnAdapt',
     'btnSpkFlat', 'btnSpkAuto'].forEach(function (id) {
      var el = $(id);
      if (el) el.disabled = !!on;
    });
    Array.prototype.forEach.call($('pillPreset').children, function (b) { b.disabled = !!on; });
    var pbg = $('pillBg');
    if (pbg) Array.prototype.forEach.call(pbg.children, function (b) { b.disabled = !!on; });
    ['btnBgOff', 'btnBgPick', 'btnBgSave', 'btnBgClear', 'btnBgRename'].forEach(function (id) {
      var el = $(id);
      if (el) el.disabled = !!on;
    });
    var pb = $('pillBits');
    if (pb) Array.prototype.forEach.call(pb.children, function (b) { b.disabled = !!on; });
    var ps = $('pillSpk');
    if (ps) Array.prototype.forEach.call(ps.children, function (b) { b.disabled = !!on; });
    var psb = $('pillSpkBits');
    if (psb) Array.prototype.forEach.call(psb.children, function (b) { b.disabled = !!on; });
    var psd = $('pillSpkDsp');
    if (psd) Array.prototype.forEach.call(psd.children, function (b) { b.disabled = !!on; });
    var pp = $('pillPa');
    if (pp) Array.prototype.forEach.call(pp.children, function (b) { b.disabled = !!on; });
    if (on && label) $('btnApply').textContent = label;
    if (!on) $('btnApply').textContent = '应用并生效';
  }

  /* -------------------------------------------------------------- commands */
  function resolveModule() {
    if (state.mod) return Promise.resolve(state.mod);

    var probes = [
      'ls -1d ' + CANDIDATES.join(' '),
      'for d in /data/adb/modules /data/adb/modules_update; do ' +
        '[ -f "$d/' + MOD_ID + '/module.prop" ] && echo "$d/' + MOD_ID + '"; done',
      'for f in /data/adb/modules/*/module.prop /data/adb/modules_update/*/module.prop; do ' +
        '[ -f "$f" ] || continue; ' +
        'grep -q "^id=' + MOD_ID + '$" "$f" && echo "${f%/module.prop}"; done'
    ];

    var i = 0;
    function attempt() {
      if (i >= probes.length) throw new Error('MODULE_DIR_NOT_FOUND');
      return sh(probes[i++]).then(function (r) {
        var first = String(r.stdout || '').split('\n')
          .map(function (s) { return s.replace(/\s+$/, ''); })
          .filter(function (s) { return s.length > 0; })[0];
        if (!first) return attempt();
        state.mod = first.replace(/\/+$/, '');
        return state.mod;
      });
    }
    return Promise.resolve().then(attempt);
  }

  function hifi(args) {
    return resolveModule().then(function (m) {
      return sh('sh ' + q(m + '/bin/hifi') + ' ' + args);
    });
  }

  function explain(e) {
    var m = String((e && e.message) || e);
    if (m === 'ROOT_BRIDGE_MISSING') {
      return '当前环境没有 KernelSU / APatch 的 Root 桥接。请用终端执行：su -c "' +
             '/data/adb/modules/' + MOD_ID + '/bin/hifi status"';
    }
    if (m === 'ROOT_BRIDGE_NO_RESULT') {
      return 'root 桥接对外可见（' + (state.bridge || '?') + '），但 ' + FORMS.length +
             ' 种调用形式没有一个回调。请把下面「自检」里的内容发出来。';
    }
    if (m === 'MODULE_DIR_NOT_FOUND') {
      return 'root 桥接是通的（' + (state.bridge || '?') + '，形式 ' + (state.form || '?') +
             '），但三种探测都没找到模块目录。说明模块没装好、被禁用，或 id 不是 ' + MOD_ID + '。';
    }
    return m;
  }

  function refresh() {
    busy(true);
    return hifi('json')
      .then(function (r) {
        var txt = String(r.stdout || '').trim();
        var start = txt.indexOf('{');
        if (start < 0) {
          throw new Error('BAD_STATUS（hifi json 没有输出 JSON，stderr: ' +
                          clip(String(r.stderr || '').trim(), 200) + '）');
        }
        renderStatus(JSON.parse(txt.slice(start)));
        busy(false);
      })
      ['catch'](function (e) {
        busy(false);
        var m = String((e && e.message) || e);
        if (m === 'ROOT_BRIDGE_MISSING') {
          $('badgeApplied').textContent = '无 Root 桥接';
          $('badgeApplied').className = 'badge off';
        }
        banner('读取状态失败：' + explain(e), true);
        renderDiag();
      });
  }

  function applySettings() {
    busy(true, '应用中…');
    return hifi('set mixer ' + state.mixer)
      .then(function () { return hifi('set max ' + state.max); })
      .then(function () { return hifi('set hifirate ' + state.hifi); })
      .then(function () { return hifi('set bitdepth ' + state.bits); })
      .then(function () { return hifi('set spk ' + state.spk); })
      .then(function () { return hifi('set spkbits ' + state.spkBits); })
      .then(function () { return hifi('set spkdsp ' + state.spkDsp); })
      .then(function () { return hifi('set bitperfect ' + (state.bp ? 1 : 0)); })
      .then(function () { return hifi('set restart ' + (state.restart ? 1 : 0)); })
      .then(function () { return hifi('set enabled 1'); })
      .then(function () { return hifi('apply'); })
      .then(function (r) {
        busy(false);
        if (r.errno !== 0) { banner('应用失败：' + ((r.stdout + r.stderr).trim() || 'unknown'), true); }
        else {
          toast('已应用 · 混音 ' + fmtHz(state.mixer) + ' / 上限 ' + fmtHz(state.max) +
                ' / HiFi 口 ' + state.hifi + ' / 位深 ' + state.bits + 'bit' +
                ' / 扬声器 ' + (state.spk === 'auto' ? 'auto' : fmtHz(state.spk)) + ' / ' + state.spkBits + 'bit' +
                ' / DSP ' + (Number(state.spkDsp) === 16 ? '关' : state.spkDsp + 'bit'));
          banner('');
        }
        return refresh();
      })
      ['catch'](function (e) { busy(false); banner('应用失败：' + explain(e), true); renderDiag(); });
  }

  function applyPreset(key) {
    var p = PRESETS[key];
    if (!p) return;
    busy(true, '应用中…');

    if (p.auto) {
      /* 自动识别：参数完全由设备端读小尾巴上报的能力决定，前端不猜 */
      return hifi('set restart ' + (state.restart ? 1 : 0))
        .then(function () { return hifi('preset auto'); })
        .then(function (r) {
          busy(false);
          var txt = ((r.stdout || '') + (r.stderr || '')).trim();
          if (r.errno !== 0) {
            banner(txt || '自动识别失败：没有检测到 USB 音频设备', true);
          } else {
            toast('已自动识别并配置');
            banner(txt, false);   /* 把识别到的能力和最终档位直接显示出来 */
          }
          return refresh();
        })
        ['catch'](function (e) { busy(false); banner('自动识别失败：' + explain(e), true); renderDiag(); });
    }

    state.mixer = p.mixer;
    state.max = p.max;
    state.bits = p.bits;
    return hifi('set restart ' + (state.restart ? 1 : 0))
      .then(function () { return hifi('preset ' + key); })
      .then(function (r) {
        busy(false);
        if (r.errno !== 0) {
          banner('预设应用失败：' + ((r.stdout + r.stderr).trim() || 'unknown'), true);
        } else {
          toast('已切换到「' + p.label + '」· ' + fmtHz(p.max) + ' / ' + p.bits + 'bit');
          banner('');
        }
        return refresh();
      })
      ['catch'](function (e) { busy(false); banner('预设应用失败：' + explain(e), true); renderDiag(); });
  }

  /* deep verification: run the on-device four-layer probe and show it in the page */
  function runDoctor() {
    var out = $('doctorBox');
    busy(true, '校验中…');
    if (out) out.textContent = '正在采集四层证据（配置层 / 系统层 / 能力层 / 链路层）…\n' +
      '提示：链路层只有在【正在播放】时才看得到，请保持音乐播放。';
    return hifi('doctor')
      .then(function (r) {
        busy(false);
        var txt = ((r.stdout || '') + (r.stderr || '')).trim();
        if (out) out.textContent = txt || '（没有输出）';
        toast('校验完成');
      })
      ['catch'](function (e) {
        busy(false);
        if (out) out.textContent = '校验失败：' + explain(e);
        banner('校验失败：' + explain(e), true);
        renderDiag();
      });
  }

  /* device adaptation info: the [8] half, kept in its own pane so the doctor
     pane above always opens straight on the live output state ([7]) */
  function runAdapt() {
    var out = $('adaptBox');
    busy(true, '采集适配信息…');
    if (out) out.textContent = '正在采集机型适配信息（策略文件 / 补丁基线 / 真实输出路径）…\n' +
      '换机型或刷入无效时，把这一整段发给维护者即可定位。';
    return hifi('adapt')
      .then(function (r) {
        busy(false);
        var txt = ((r.stdout || '') + (r.stderr || '')).trim();
        if (out) out.textContent = txt || '（没有输出）';
        toast('适配信息已采集');
      })
      ['catch'](function (e) {
        busy(false);
        if (out) out.textContent = '采集失败：' + explain(e);
        banner('采集失败：' + explain(e), true);
        renderDiag();
      });
  }

  /* speaker one-tap best practice: `hifi speaker flat|auto` (tier handled
     entirely on the device side, WebUI only fires the subcommand) */
  function runSpeaker(tier) {
    busy(true, '优化中…');
    return hifi('speaker ' + tier)
      .then(function (r) {
        busy(false);
        var txt = ((r.stdout || '') + (r.stderr || '')).trim();
        if (r.errno !== 0) {
          banner('扬声器' + (tier === 'auto' ? '还原' : '优化') + '失败：' + (txt || 'unknown'), true);
        } else {
          toast(tier === 'auto' ? '扬声器已还原原厂' : '扬声器已优化 (44.1k / 24bit)');
        }
        return refresh();
      })
      ['catch'](function (e) {
        busy(false);
        banner('扬声器' + (tier === 'auto' ? '还原' : '优化') + '失败：' + explain(e), true);
        renderDiag();
      });
  }

  /* smart PA loudspeaker gain: `hifi pa gain <n>` (n=0 => `pa gain reset`).
     Two-step confirm: the FIRST click on a tier only shows the warning (the
     banner doubles as the confirmation line), the SECOND click on the SAME
     tier actually fires the command.  Any other click resets the arm. */
  function runPaGain(n) {
    if (state.paConfirm !== n) {
      state.paConfirm = n;
      var lvl = n === 0 ? '回到出厂 0（原厂功率，最安全）'
                        : '把扬声器 PA 增益提高到 +' + n + 'dB';
      banner('⚠ ' + lvl + ' —— 这会直接增大扬声器驱动功率，可能造成振膜损伤/失真/硬件损坏。' +
             '再次点击同一档确认执行；听到破音立即回出厂 0。', true);
      return;
    }
    state.paConfirm = null;
    busy(true, '调整 PA…');
    var tier = n === 0 ? 'gain reset' : 'gain ' + n;
    return hifi('pa ' + tier)
      .then(function (r) {
        busy(false);
        var txt = ((r.stdout || '') + (r.stderr || '')).trim();
        if (r.errno !== 0) {
          banner('Smart PA 调整失败：' + (txt || 'unknown'), true);
        } else {
          toast(n === 0 ? 'PA 增益已回出厂 0' : 'PA 增益已设为 +' + n + 'dB');
          banner(txt, false);
        }
        return refresh();
      })
      ['catch'](function (e) {
        busy(false);
        banner('Smart PA 调整失败：' + explain(e), true);
        renderDiag();
      });
  }

  /* one-tap restore: lossless, reversible, settings are kept */
  function restoreFactory() {
    var msg = '一键还原：立即卸载补丁、回到原厂音频策略，并重启音频服务。\n\n' +
              '· 无损且可逆，原厂文件从未被改写\n' +
              '· 当前播放会中断\n' +
              '· 你设过的参数会保留，随时可以再启用\n\n确定继续？';
    if (!window.confirm(msg)) return;
    busy(true, '还原中…');
    hifi('restore').then(function (r) {
      busy(false);
      if (r.errno !== 0) {
        banner('还原失败：' + ((r.stdout + r.stderr).trim() || 'unknown'), true);
      } else {
        toast('已一键还原为原厂策略');
        banner('');
      }
      return refresh();
    })['catch'](function (e) { busy(false); banner('还原失败：' + explain(e), true); renderDiag(); });
  }

  /* ---------------------------------------------------------------- events */
  document.addEventListener('click', function (ev) {
    var el = ev.target.closest ? ev.target.closest('.pill') : null;
    if (!el) return;
    var host = el.parentNode;
    if (host.id === 'pillPreset') { applyPreset(el.dataset.p); return; }
    if (host.id === 'pillMax') state.max = Number(el.dataset.v);
    else if (host.id === 'pillMixer') state.mixer = Number(el.dataset.v);
    else if (host.id === 'pillHifi') state.hifi = el.dataset.h;
    else if (host.id === 'pillBits') { state.bits = Number(el.dataset.b); renderBits(); return; }
    else if (host.id === 'pillSpk') { state.spk = el.dataset.v === 'auto' ? 'auto' : Number(el.dataset.v); renderSpk(); return; }
    else if (host.id === 'pillSpkBits') { state.spkBits = Number(el.dataset.b); renderSpkBits(); return; }
    else if (host.id === 'pillBp') { state.bp = Number(el.dataset.bp); renderBp(); return; }
    else if (host.id === 'pillSpkDsp') { state.spkDsp = Number(el.dataset.d); renderSpkDsp(); return; }
    else if (host.id === 'pillPa') { runPaGain(Number(el.dataset.g)); return; }
    else return;
    renderPills();
  });

  $('btnRestart').addEventListener('click', function () {
    state.restart = !state.restart;
    renderPills();
  });
  $('btnApply').addEventListener('click', applySettings);
  $('btnReset').addEventListener('click', restoreFactory);
  $('btnRefresh').addEventListener('click', function () { refresh(); toast('已刷新'); });
  $('btnDac').addEventListener('click', function () {
    busy(true);
    hifi('dac').then(function () { return refresh(); }).then(function () {
      busy(false);
      toast('已重新检测');
    })['catch'](function (e) { busy(false); banner('检测失败：' + explain(e), true); renderDiag(); });
  });

  /* force a full re-probe of the root bridge and of the module directory */
  var btnDiag = $('btnDiag');
  if (btnDiag) {
    btnDiag.addEventListener('click', function () {
      state.mod = null;
      state.form = null;
      negotiation = null;
      state.last = null;
      renderDiag();
      refresh();
      toast('已重新自检');
    });
  }

  var btnDoctor = $('btnDoctor');
  if (btnDoctor) btnDoctor.addEventListener('click', runDoctor);
  var btnAdapt = $('btnAdapt');
  if (btnAdapt) btnAdapt.addEventListener('click', runAdapt);
  var btnSpkFlat = $('btnSpkFlat');
  if (btnSpkFlat) btnSpkFlat.addEventListener('click', function () { runSpeaker('flat'); });
  var btnSpkAuto = $('btnSpkAuto');
  if (btnSpkAuto) btnSpkAuto.addEventListener('click', function () { runSpeaker('auto'); });

  renderPills();
  renderBits();
  renderSpk();
  renderSpkBits();
  renderSpkDsp();
  renderPa();
  renderBp();
  bgInit();
  bgBind();
  renderDiag();
  refresh();
})();
