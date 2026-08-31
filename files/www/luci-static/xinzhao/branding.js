(function () {
  'use strict';

  function applyBranding(info) {
    var name = info.Firmware || 'XinZhaoWrt';
    document.title = name + (document.title ? ' - ' + document.title.replace(/^.*?\s-\s/, '') : '');
    applyThemeLayout();
    if (!/\/admin\/status(?:\/overview)?(?:\/|$)/.test(window.location.pathname)) return;
    var main = document.querySelector('#maincontent, #content');
    if (!main || document.getElementById('xinzhao-build-info')) return;
    var card = document.createElement('section');
    card.id = 'xinzhao-build-info';
    card.className = 'cbi-section';
    card.innerHTML = '<h3>' + name + '</h3>' +
      '<div class="cbi-value"><label class="cbi-value-title">固件版本</label><div class="cbi-value-field">' +
      name + ' ' + (info.Version || '') + '</div></div>' +
      '<div class="cbi-value"><label class="cbi-value-title">编译者</label><div class="cbi-value-field">' + (info.Builder || '') + '</div></div>' +
      '<div class="cbi-value"><label class="cbi-value-title">编译时间</label><div class="cbi-value-field">' + (info['Build Date'] || '') + '</div></div>' +
      '<div class="cbi-value"><label class="cbi-value-title">Git Commit</label><div class="cbi-value-field">' + (info['Git Commit'] || '') + '</div></div>' +
      '<div class="cbi-value"><label class="cbi-value-title">Build ID</label><div class="cbi-value-field">' + (info['Build ID'] || '') + '</div></div>';
    main.insertBefore(card, main.firstChild);
  }

  function applyThemeLayout() {
    if (document.getElementById('xinzhao-branding-style')) return;
    var style = document.createElement('style');
    style.id = 'xinzhao-branding-style';
    style.textContent = [
      '.main-left .sidenav-header .brand { display:flex !important; align-items:center; justify-content:center; gap:.45rem; margin:0 .5rem !important; max-width:calc(100% - 1rem); white-space:nowrap; overflow:hidden; }',
      '.main-left .sidenav-header .brand .xz-brand-logo { display:block; width:72px; height:72px; max-width:72px; max-height:72px; object-fit:contain; flex:0 0 72px; }',
      '.main-left .sidenav-header .brand .xz-brand-label { min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }',
      'header .brand { display:inline-flex !important; align-items:center; gap:.35rem; white-space:nowrap; }',
      'header .brand .xz-brand-logo { display:block; width:32px; height:32px; max-width:32px; max-height:32px; object-fit:contain; flex:0 0 32px; }'
    ].join('');
    document.head.appendChild(style);
  }

  fetch('/luci-static/xinzhao/build-info.json', { credentials: 'same-origin' })
    .then(function (response) { return response.ok ? response.json() : null; })
    .then(function (info) { if (info) applyBranding(info); })
    .catch(function () {});
}());
