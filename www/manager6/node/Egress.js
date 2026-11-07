Ext.define('PVE.node.Egress', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveNodeEgress',
    layout: { type: 'vbox', align: 'stretch' },
    scrollable: true,
    bodyPadding: 10,

    initComponent: function () {
        let me = this;
        let node = me.pveSelNode.data.node;
        let caps = Ext.state.Manager.get('GuiCap');
        let writable = !!caps.nodes['Sys.Modify'];
        let state;
        let secrets = {};
        let dirty = false;
        let endpoint = '/nodes/' + encodeURIComponent(node) + '/egress';
        let info = Ext.create('Ext.Component', { padding: 10, html: '正在读取出站配置…' });
        let deployment = Ext.create('Proxmox.form.KVComboBox', {
            fieldLabel: '网关位置', value: 'host', width: 330, disabled: !writable,
            comboItems: [['host', 'PVE 宿主'], ['gateway-vm', '独立网关 VM']],
            listeners: { change: function () { dirty = true; } },
        });
        let providerStore = Ext.create('Ext.data.Store', { fields: ['id', 'protocol', 'server', 'port', 'udp'] });
        let envStore = Ext.create('Ext.data.Store', { fields: ['id', 'interface', 'provider', 'dns', 'udp', 'ipv6', 'mode', 'status'] });
        let refreshStores = function () {
            providerStore.loadData(Object.entries(state.config.providers).map(([id, p]) => ({ id, ...p })));
            envStore.loadData(state.config.environments.map(e => ({ ...e, mode: e.lease.mode,
                status: state.runtime[e.id]?.reason || '尚未应用' })));
        };
        let load = function () {
            Proxmox.Utils.API2Request({ url: endpoint, method: 'GET', waitMsgTarget: me,
                success: function (response) {
                    state = response.result.data;
                    secrets = {};
                    deployment.setValue(state.config.deployment);
                    dirty = false;
                    refreshStores();
                    info.update('草稿版本 ' + state.revision + ' · 已应用版本 ' + (state.applied?.revision ?? '无') +
                        '。保存只更新草稿；应用会中断旧连接，检查失败时不开放直连。');
                },
                failure: function (r) { Ext.Msg.alert('读取失败', r.htmlStatus); },
            });
        };
        let combo = (name, label, values, value) => ({ xtype: 'combobox', name, fieldLabel: label,
            store: values, queryMode: 'local', editable: false, forceSelection: true, value, allowBlank: false });
        let field = (name, label, value, optional = false) => ({ xtype: 'textfield', name, fieldLabel: label,
            value: value || '', allowBlank: optional });
        let edit = function (type, original) {
            if (!state) { return; }
            let provider = type === 'provider';
            let value = original || (provider ? { protocol: 'socks5', port: 1080, udp: false } :
                { port: 15000, dns: 'proxy', dns_server: '1.1.1.1', udp: 'block', ipv6: 'block', lease: { mode: 'rotating' } });
            let id = provider ? original?.id : value.id;
            let fields = provider ? [
                field('id', '供应商标识', id), combo('protocol', '协议', ['http', 'socks5'], value.protocol),
                field('server', '服务器 IP', value.server),
                { xtype: 'numberfield', name: 'port', fieldLabel: '端口', minValue: 1, maxValue: 65535, value: value.port, allowBlank: false },
                { xtype: 'checkbox', name: 'udp', fieldLabel: '供应商支持 UDP', checked: value.udp },
                field('username_template', '会话用户名模板', value.username_template, true),
                field('username', '认证用户名', '', true),
                { ...field('password', '新密码（留空保留）', '', true), inputType: 'password' },
                { xtype: 'checkbox', name: 'clear', fieldLabel: '清除已存认证' },
            ] : [
                field('id', '环境标识', value.id), field('interface', '专属 LAN 接口', value.interface),
                combo('provider', '供应商', Object.keys(state.config.providers), value.provider),
                { xtype: 'numberfield', name: 'port', fieldLabel: '代理监听端口', minValue: 1024, maxValue: 55000, value: value.port, allowBlank: false },
                combo('dns', 'DNS 策略', ['proxy', 'direct', 'block'], value.dns), field('dns_server', 'DNS 解析器 IP', value.dns_server),
                combo('udp', 'UDP 策略', ['proxy', 'block'], value.udp), combo('ipv6', 'IPv6 策略', ['proxy', 'block'], value.ipv6),
                combo('mode', '出口租约', ['rotating', 'fixed', 'sticky'], value.lease.mode),
                field('expected_ip', '预期出口 IP', value.lease.expected_ip, true), field('session', '粘性会话标识', value.lease.session, true),
                field('expires_at', '到期时间（含时区）', value.lease.expires_at, true),
            ];
            if (original) { fields[0].readOnly = true; }
            let form = Ext.create('Ext.form.Panel', { bodyPadding: 15, defaults: { anchor: '100%', labelWidth: 165 }, items: fields });
            let win = Ext.create('Ext.window.Window', { title: provider ? '编辑代理供应商' : '编辑环境出站策略',
                modal: true, width: 620, maxHeight: 750, scrollable: true, layout: 'fit', items: [form],
                buttons: [{ text: '取消', handler: () => win.close() }, { text: '确定', handler: function () {
                    if (!form.isValid()) { return; }
                    let data = form.getValues();
                    if (provider) {
                        if (!original && state.config.providers[data.id]) { Ext.Msg.alert('错误', '供应商标识已存在'); return; }
                        let item = { protocol: data.protocol, server: data.server, port: Number(data.port), udp: !!data.udp };
                        if (data.username_template) { item.username_template = data.username_template; }
                        state.config.providers[data.id] = item;
                        if (data.clear) { secrets[data.id] = null; }
                        else if (data.password || data.username) { secrets[data.id] = { username: data.username, password: data.password }; }
                    } else {
                        if (!original && state.config.environments.some(e => e.id === data.id)) { Ext.Msg.alert('错误', '环境标识已存在'); return; }
                        let lease = { mode: data.mode };
                        for (let key of ['expected_ip', 'session', 'expires_at']) { if (data[key]) { lease[key] = data[key]; } }
                        let item = { id: data.id, interface: data.interface, provider: data.provider, port: Number(data.port),
                            dns: data.dns, dns_server: data.dns_server, udp: data.udp, ipv6: data.ipv6, lease };
                        state.config.environments = state.config.environments.filter(e => e.id !== item.id).concat([item]);
                    }
                    dirty = true; refreshStores(); win.close();
                } }],
            });
            win.show();
        };
        let grid = function (provider) {
            let store = provider ? providerStore : envStore;
            let columns = provider ? [['id', '供应商'], ['protocol', '协议'], ['server', '服务器'], ['port', '端口']] :
                [['id', '环境'], ['interface', 'LAN'], ['provider', '供应商'], ['dns', 'DNS'], ['udp', 'UDP'], ['ipv6', 'IPv6'], ['mode', '租约'], ['status', '运行状态']];
            let panel = Ext.create('Ext.grid.Panel', { title: provider ? '代理供应商' : '环境出站策略', minHeight: 190,
                flex: 1, margin: '0 0 12 0', store,
                columns: columns.map(([dataIndex, text]) => ({ dataIndex, text, flex: 1, renderer: Ext.htmlEncode })),
                tbar: [{ text: '添加', disabled: !writable, handler: () => edit(provider ? 'provider' : 'environment') },
                    { text: '编辑', disabled: !writable, handler: function () {
                        let selected = panel.getSelection()[0];
                        if (selected) { edit(provider ? 'provider' : 'environment', provider ? selected.data : state.config.environments.find(e => e.id === selected.data.id)); }
                    } }],
                listeners: { itemdblclick: function (g, rec) {
                    if (writable) { edit(provider ? 'provider' : 'environment', provider ? rec.data : state.config.environments.find(e => e.id === rec.data.id)); }
                } },
            });
            return panel;
        };
        let document = () => ({ revision: state.revision, config: { ...state.config, deployment: deployment.getValue() }, secrets });
        me.tbar = [deployment, { text: '刷新', handler: function () {
            if (dirty) { Ext.Msg.confirm('放弃未保存修改？', '刷新将重新读取服务端草稿。', answer => { if (answer === 'yes') { load(); } }); }
            else { load(); }
        } }, { text: '校验', disabled: !writable, handler: function () {
            if (!state) { return; }
            Proxmox.Utils.API2Request({ url: endpoint + '/validate', method: 'POST', params: { document: JSON.stringify(document()) },
                success: () => Ext.Msg.alert('校验通过', '策略组合有效，保存后可应用。'), failure: r => Ext.Msg.alert('校验失败', r.htmlStatus) });
        } }, { text: '保存草稿', disabled: !writable, handler: function () {
            if (!state) { return; }
            Proxmox.Utils.API2Request({ url: endpoint + '/config', method: 'PUT', params: { document: JSON.stringify(document()) },
                waitMsgTarget: me, success: load, failure: r => Ext.Msg.alert('保存失败', r.htmlStatus) });
        } }, { text: '应用已保存配置', disabled: !writable, handler: function () {
            if (!state || dirty) { Ext.Msg.alert('请先保存', '应用只针对已保存版本，请先保存修改。'); return; }
            Ext.Msg.confirm('应用出站策略', '将关闭旧代理连接并重新检查隔离网络，是否继续？', answer => {
                if (answer !== 'yes') { return; }
                Proxmox.Utils.API2Request({ url: endpoint + '/apply', method: 'POST', params: { revision: state.revision },
                    success: r => Ext.create('Proxmox.window.TaskViewer', { upid: r.result.data, autoShow: true, listeners: { destroy: load } }),
                    failure: r => Ext.Msg.alert('应用失败', r.htmlStatus) });
            });
        } }];
        me.items = [info, grid(true), grid(false)];
        me.callParent();
        me.on('afterrender', load, me, { single: true });
    },
});
