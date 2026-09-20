/* HiFi SRC Bypass - WebUI front-end  (universal, v1.9.0)
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
  var SPK_BITS = [
    [16, '16-bit', '保持原厂（默认）'],
    [24, '24-bit', '16 + 24bit'],
    [32, '32-bit', '16 + 24 + 32bit']
  ];

  var state = {
    mod: null, mixer: 48000, max: 384000, bits: 32, hifi: 'auto',
    spk: 'auto', spkBits: 16,
    restart: true, applied: false, enabled: 1,
    bridge: null,          /* which window object answered                   */
    form: null,            /* which call signature that object speaks        */
    last: null             /* last raw result, for the self test             */
  };

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
    state.restart = !(s.restart === 0 || s.restart === false);
    state.applied = !!s.applied;
    state.enabled = s.enabled === 0 ? 0 : 1;

    $('badgeVersion').textContent = 'v' + (s.version || '?');
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
    var pb = $('pillBits');
    if (pb) Array.prototype.forEach.call(pb.children, function (b) { b.disabled = !!on; });
    var ps = $('pillSpk');
    if (ps) Array.prototype.forEach.call(ps.children, function (b) { b.disabled = !!on; });
    var psb = $('pillSpkBits');
    if (psb) Array.prototype.forEach.call(psb.children, function (b) { b.disabled = !!on; });
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
      .then(function () { return hifi('set restart ' + (state.restart ? 1 : 0)); })
      .then(function () { return hifi('set enabled 1'); })
      .then(function () { return hifi('apply'); })
      .then(function (r) {
        busy(false);
        if (r.errno !== 0) { banner('应用失败：' + ((r.stdout + r.stderr).trim() || 'unknown'), true); }
        else {
          toast('已应用 · 混音 ' + fmtHz(state.mixer) + ' / 上限 ' + fmtHz(state.max) +
                ' / HiFi 口 ' + state.hifi + ' / 位深 ' + state.bits + 'bit' +
                ' / 扬声器 ' + (state.spk === 'auto' ? 'auto' : fmtHz(state.spk)) + ' / ' + state.spkBits + 'bit');
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
  renderDiag();
  refresh();
})();
