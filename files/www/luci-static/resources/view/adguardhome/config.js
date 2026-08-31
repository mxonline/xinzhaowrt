'use strict';
'require view';
'require dom';
'require fs';
'require rpc';
'require ui';

var serviceList = rpc.declare({ object: 'service', method: 'list', params: [ 'name' ], expect: {} });
// service.action is used for lifecycle operations so procd remains authoritative.
var serviceAction = rpc.declare({ object: 'service', method: 'action', params: [ 'name', 'action' ], expect: {} });
var lanStatus = rpc.declare({ object: 'network.interface.lan', method: 'status', expect: {} });
var configPath = '/etc/adguardhome/adguardhome.yaml';
var backupPath = '/etc/adguardhome/adguardhome.yaml.xinzhao-backup';
// Visible strings are translated by luci-i18n-adguardhome-zh-cn through _().

function button(label, action, style) {
	return E('button', { 'class': 'cbi-button cbi-button-' + (style || 'default'), 'click': action }, [ _(label) ]);
}

function runService(action) {
	return function() {
		return serviceAction('adguardhome', action).then(function() {
			ui.addNotification(null, E('p', _('服务操作已执行：') + _(action)), 'info');
			return this.refresh();
		}.bind(this)).catch(function(error) { ui.addNotification(null, E('p', _('服务操作失败：') + error), 'error'); });
	}.bind(this);
}

function statusText(data) {
	var instance = data && data.adguardhome && data.adguardhome.instances && data.adguardhome.instances.adguardhome;
	return instance && instance.running ? _('运行中') : _('未运行');
}

return view.extend({
	load: function() {
		return Promise.all([ serviceList('adguardhome'), fs.exec('/usr/bin/AdGuardHome', [ '--version' ]).catch(function() { return { stdout: _('未知版本') }; }), lanStatus().catch(function() { return {}; }) ]);
	},
	refresh: function() {
		return serviceList('adguardhome').then(function(data) {
			var node = document.querySelector('[data-adguard-status]');
			if (node) dom.content(node, statusText(data));
		});
	},
	readYaml: function(editor) {
		return fs.read(configPath).then(function(text) { editor.value = text || ''; }).catch(function(error) { ui.addNotification(null, E('p', _('读取配置失败：') + error), 'error'); });
	},
	validateYaml: function(editor) {
		return fs.exec('/usr/bin/AdGuardHome', [ '--check-config', '--config', configPath ]).then(function(result) {
			if (result.code) throw new Error(result.stderr || _('YAML 校验失败'));
			ui.addNotification(null, E('p', _('YAML 校验通过')), 'info');
			return true;
		}).catch(function(error) { ui.addNotification(null, E('p', _('YAML 校验失败：') + error), 'error'); return false; });
	},
	saveYaml: function(editor) {
		return this.validateYaml(editor).then(function(ok) {
			if (!ok) return;
			return fs.exec('/bin/cp', [ configPath, backupPath ]).catch(function() { return null; }).then(function() {
				return fs.write(configPath, editor.value);
			}).then(function() { return serviceAction('adguardhome', 'restart'); }).then(function() {
				ui.addNotification(null, E('p', _('配置已保存并安全重启')), 'info');
			}).catch(function(error) {
				return fs.exec('/bin/cp', [ backupPath, configPath ]).then(function() { return serviceAction('adguardhome', 'restart'); }).catch(function() {}).then(function() {
					ui.addNotification(null, E('p', _('保存失败，已回滚到上一份有效配置：') + error), 'error');
				});
			});
		});
	},
	render: function(data) {
		var self = this;
		var version = (data[1] && data[1].stdout || _('未知版本')).trim();
		var lan = data[2] && data[2]['ipv4-address'] && data[2]['ipv4-address'][0] && data[2]['ipv4-address'][0].address;
		var webUrl = 'http://' + (lan || window.location.hostname) + ':3000/';
		var logPre = E('pre', { 'class': 'cbi-section', 'data-adguard-log': '1' }, [ _('正在读取运行日志…') ]);
		var editor = E('textarea', { 'class': 'cbi-input-textarea', 'style': 'width:100%;min-height:28rem;font-family:monospace', 'spellcheck': 'false' });
		var tabs = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, [ _('AdGuard Home') ]),
			E('div', { 'class': 'cbi-map-tabbed' }, [
				E('h3', {}, [ _('基础设置') ]),
				E('section', { 'class': 'cbi-section' }, [
					E('div', { 'class': 'table' }, [ E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('服务状态') ]), E('div', { 'class': 'td', 'data-adguard-status': '1' }, [ statusText(data[0]) ]) ]), E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('当前核心版本') ]), E('div', { 'class': 'td' }, [ version ]) ]), E('div', { 'class': 'tr' }, [ E('div', { 'class': 'td left' }, [ _('Web 管理端口') ]), E('div', { 'class': 'td' }, [ '3000' ]) ]) ]),
					E('div', { 'class': 'cbi-page-actions' }, [ button('启用', runService.call(self, 'enable')), button('启动', runService.call(self, 'start')), button('停止', runService.call(self, 'stop')), button('重启', runService.call(self, 'restart')), E('a', { 'class': 'cbi-button cbi-button-action', 'href': webUrl, 'target': '_blank' }, [ _('打开 AdGuard Home Web') ]), button('检查核心更新', function() { ui.addNotification(null, E('p', _('请使用 AdGuardTeam 官方 Release 检查更新。')), 'info'); }), button('手动更新核心', function() { ui.addNotification(null, E('p', _('手动更新需经官方 Release 验证后执行。')), 'info'); }) ])
				]),
				E('h3', {}, [ _('日志') ]), E('section', { 'class': 'cbi-section' }, [ E('div', { 'class': 'cbi-page-actions' }, [ button('自动刷新', function() { self.refreshLogs(logPre, false); }), button('暂停', function() { logPre.dataset.paused = '1'; }), button('正序', function() { self.refreshLogs(logPre, false); }), button('倒序', function() { self.refreshLogs(logPre, true); }), button('清空', function() { logPre.textContent = ''; }), button('下载', function() { fs.write('/tmp/adguardhome-log.txt', logPre.textContent).then(function() { window.location.href = '/cgi-bin/luci/admin/system/flashops/backup?file=/tmp/adguardhome-log.txt'; }); }) ]), logPre ]),
				E('h3', {}, [ _('手动设置') ]), E('section', { 'class': 'cbi-section' }, [ E('p', {}, [ _('AdGuardHome.yaml') ]), editor, E('div', { 'class': 'cbi-page-actions' }, [ button('读取', self.readYaml.bind(self, editor)), button('编辑', function() { editor.focus(); }), button('YAML 校验', self.validateYaml.bind(self, editor)), button('保存', self.saveYaml.bind(self, editor), 'apply'), button('备份', function() { return fs.exec('/bin/cp', [ configPath, backupPath ]); }), button('恢复', function() { return fs.exec('/bin/cp', [ backupPath, configPath ]).then(function() { return serviceAction('adguardhome', 'restart'); }); }) ]) ])
			])
		]);
		this.readYaml(editor);
		this.refreshLogs(logPre, false);
		return tabs;
	},
	refreshLogs: function(node, reverse) {
		if (node.dataset.paused === '1') return Promise.resolve();
		return fs.exec('/usr/bin/logread', [ '-e', 'AdGuardHome' ]).then(function(result) { var text = result.stdout || ''; if (reverse) text = text.split('\n').reverse().join('\n'); node.textContent = text || _('暂无运行日志'); });
	}
});
