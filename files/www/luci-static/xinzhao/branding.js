(function () {
  'use strict';

  function applyBranding(info) {
    var name = info.Firmware || 'XinZhaoWrt';
    document.title = name + (document.title ? ' - ' + document.title.replace(/^.*?\s-\s/, '') : '');
    if (!/\/admin\/status\/overview(?:\/|$)/.test(window.location.pathname)) return;
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

  fetch('/luci-static/xinzhao/build-info.json', { credentials: 'same-origin' })
    .then(function (response) { return response.ok ? response.json() : null; })
    .then(function (info) { if (info) applyBranding(info); })
    .catch(function () {});
}());
