/* SILAS WorkTime · Alertas e dispositivos — integra-se com o Supabase real.
   Sem migration, mostra indicação de configuração pendente, sem simular dados. */
(()=>{'use strict';
const $=s=>document.querySelector(s);
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const DT=iso=>iso?new Intl.DateTimeFormat('pt-PT',{timeZone:'Europe/Lisbon',dateStyle:'short',timeStyle:'short'}).format(new Date(iso)):'—';
const KEY='silas-worktime-device-id-v1';
let app=null;
function deviceId(){let id;try{id=localStorage.getItem(KEY);if(!id||!/^[a-f\d-]{36}$/i.test(id)){id=crypto.randomUUID();localStorage.setItem(KEY,id)}}catch{id=crypto.randomUUID()}return id}
function deviceLabel(){const os=/iPhone/i.test(navigator.userAgent)?'iPhone':/iPad/i.test(navigator.userAgent)?'iPad':/Android/i.test(navigator.userAgent)?'Android':/Mac/i.test(navigator.userAgent)?'Mac':/Windows/i.test(navigator.userAgent)?'Windows':'Dispositivo';return `${os} · ${/Firefox/i.test(navigator.userAgent)?'Firefox':/Edg/i.test(navigator.userAgent)?'Edge':/Chrome/i.test(navigator.userAgent)?'Chrome':/Safari/i.test(navigator.userAgent)?'Safari':'Navegador'}`}
async function checkDevice(sb){
 const {data,error}=await sb.rpc('worktime_register_device',{p_device_id:deviceId(),p_label:deviceLabel(),p_user_agent:navigator.userAgent.slice(0,500)});
 if(error){if(/PGRST202|could not find the function|does not exist|404/i.test(String(error.code||'')+' '+error.message))return {status:'not_configured'};throw error}
 return data;
}
const defaultPrefs=()=>({enabled:false,browser_enabled:false,absence_enabled:true,late_enabled:true,recurring_late_enabled:true,devices_enabled:true,missing_entry_enabled:true,recurring_late_threshold:3});
const allows=(p,kind)=>!!({device_pending:p.devices_enabled,device_new_admin:p.devices_enabled,late:p.late_enabled,recurring_late:p.recurring_late_enabled,possible_absence:p.absence_enabled,missing_entry:p.missing_entry_enabled})[kind];
function create({sb,getAdmin,toast}){
 if(app)app.stop();
 let prefs=defaultPrefs(),alerts=[],devices=[],reads=new Set(),configured=null,loading=false,dirty=false,pollTimer=null,lastScan=0,shown=new Set(),initialLoad=true,errorText='';
 const admin=getAdmin();
 const api={
  stop(){clearInterval(pollTimer);if(app===api)app=null;},
  unreadCount(){return !prefs.enabled?devices.filter(d=>d.status==='pending').length:alerts.filter(a=>allows(prefs,a.kind)&&!reads.has(a.id)).length;},
  async refresh(forceScan=false){
   if(loading)return;loading=true;
   try{
    if(forceScan||Date.now()-lastScan>180000){const scan=await sb.rpc('worktime_scan_attendance_alerts');if(scan.error)throw scan.error;lastScan=Date.now()}
    const [a,d,p,r]=await Promise.all([
      sb.from('worktime_alerts').select('id,kind,employee_id,title,body,work_date,created_at').order('created_at',{ascending:false}).limit(160),
      sb.from('worktime_device_authorizations').select('id,profile_id,label,status,requested_at,decided_at,last_seen_at').order('requested_at',{ascending:false}).limit(100),
      sb.from('worktime_alert_preferences').select('*').eq('admin_profile_id',admin.id).maybeSingle(),
      sb.from('worktime_alert_reads').select('alert_id').eq('admin_profile_id',admin.id).limit(300)
    ]);
    for(const x of [a,d,p,r])if(x.error)throw x.error;
    configured=true;errorText='';alerts=a.data||[];devices=d.data||[];prefs={...defaultPrefs(),...(p.data||{})};reads=new Set((r.data||[]).map(x=>x.alert_id));
    // Alertas nativos apenas enquanto o website está aberto. Sem web push.
    const fresh=alerts.filter(x=>allows(prefs,x.kind)&&!reads.has(x.id)&&Date.now()-Date.parse(x.created_at)<15*60000&&!shown.has(x.id));
    if(initialLoad){fresh.forEach(x=>shown.add(x.id));initialLoad=false}
    else if(prefs.enabled&&prefs.browser_enabled&&'Notification' in window&&Notification.permission==='granted'&&fresh.length){
      fresh.forEach(x=>shown.add(x.id));
      try{new Notification(fresh.length>1?`${fresh.length} novos alertas · SILAS`:fresh[0].title,{body:fresh.length>1?fresh.slice(0,2).map(x=>x.title).join(' · '):fresh[0].body,tag:'silas-admin-alerts'})}catch{}
    }
   }catch(e){configured=false;errorText=/PGRST202|does not exist|relation .* does not exist|404|42P01/i.test(String(e.code||'')+' '+e.message)?'Falta instalar o módulo de alertas na base de dados. Consulta as instruções incluídas no ZIP.':String(e.message||'Não foi possível carregar alertas.');}
   finally{loading=false;drawBadge();if($('#alertCenterPage')&&!dirty)api.render($('#viewRoot'))}
  },
  start(){api.refresh(true);pollTimer=setInterval(()=>{if(document.visibilityState==='visible'&&navigator.onLine)api.refresh()},45000)},
  render(root){if(!root)return;
   const pending=devices.filter(x=>x.status==='pending'), approved=devices.filter(x=>x.status==='approved'), history=devices.filter(x=>x.status==='rejected'||x.status==='revoked');
   const display=alerts.filter(a=>allows(prefs,a.kind)||!prefs.enabled);
   root.innerHTML=`<div class="content alert-center" id="alertCenterPage"><div class="alert-page-head"><div><span class="panel-kicker">SILAS · Segurança e assiduidade</span><h1>Notificações</h1><p>Avisos para a Katia sobre a equipa e novos dispositivos.</p></div><button id="alertManualRefresh" class="btn btn-soft">Atualizar</button></div>
   ${configured===false?`<div class="alert-error" role="alert"><strong>Configuração necessária</strong><p>${esc(errorText)}</p><small>A aplicação anterior continua disponível. As novas notificações e autorizações não funcionam enquanto o SQL não estiver instalado.</small></div>`:''}
   <div class="alert-layout"><section class="alert-panel"><div class="alert-panel-head"><div><h2>Ativar notificações</h2><p>Escolhe os acontecimentos que queres acompanhar.</p></div><label class="alert-switch"><input id="alertEnabled" type="checkbox" ${prefs.enabled?'checked':''} ${configured===false?'disabled':''}><span>${prefs.enabled?'Ativadas':'Desativadas'}</span></label></div>
   <div class="alert-preferences">${[
   ['absence_enabled','Possíveis faltas','Só depois de terminar o turno, sem entrada nem estado justificado.'],
   ['missing_entry_enabled','Entradas por registar','Quando já passaram 45 minutos desde o início previsto.'],
   ['late_enabled','Entradas com atraso','Tendo em conta a tolerância definida nos horários.'],
   ['recurring_late_enabled','Atrasos repetidos','Quando o funcionário ultrapassa o limite de atrasos em 30 dias.'],
   ['devices_enabled','Dispositivos não autorizados','Pedidos de novos dispositivos e acessos de administração.']
   ].map(([k,t,d])=>`<label class="alert-pref"><input type="checkbox" data-alert-pref="${k}" ${prefs[k]?'checked':''} ${configured===false?'disabled':''}><span><strong>${t}</strong><small>${d}</small></span></label>`).join('')}
   <label class="alert-pref alert-pref-inline"><span><strong>Alertar a partir de</strong><small>Número de atrasos nos últimos 30 dias</small></span><select id="alertThreshold" ${configured===false?'disabled':''}>${[2,3,4,5,6].map(n=>`<option value="${n}" ${+prefs.recurring_late_threshold===n?'selected':''}>${n} atrasos</option>`).join('')}</select></label>
   <label class="alert-pref"><input id="alertBrowser" type="checkbox" ${prefs.browser_enabled?'checked':''} ${configured===false?'disabled':''}><span><strong>Avisos do navegador</strong><small>Aparecem quando o SILAS está aberto neste dispositivo e o navegador permite.</small></span></label>
   <div class="alert-actions"><button id="alertSave" class="btn btn-primary" ${configured===false?'disabled':''}>Guardar preferências</button><small>${'Notification' in window?'Permissão do navegador: '+({'granted':'permitida','denied':'bloqueada','default':'por pedir'}[Notification.permission]||Notification.permission):'Este navegador não suporta avisos nativos.'}</small></div></div></section>
   <section class="alert-panel"><div class="alert-panel-head"><div><h2>Caixa de entrada</h2><p>${api.unreadCount()} aviso(s) por tratar · últimos acontecimentos</p></div></div><div class="alert-items">${display.map(a=>`<article class="alert-item ${reads.has(a.id)?'read':'unread'}"><span class="alert-dot"></span><div class="alert-item-content"><strong>${esc(a.title)}</strong><p>${esc(a.body)}</p><small>${DT(a.created_at)}</small></div>${!reads.has(a.id)?`<button class="btn btn-soft" data-alert-read="${a.id}">Lido</button>`:''}</article>`).join('')||'<div class="alert-empty">Ainda não existem alertas registados.</div>'}</div></section></div>
   <section class="alert-panel alert-device-panel"><div class="alert-panel-head"><div><h2>Dispositivos</h2><p>Aprova ou recusa novos telemóveis e computadores da equipa.</p></div><span class="badge ${pending.length?'amber':'green'}">${pending.length} pendente(s)</span></div>
   ${pending.map(x=>deviceRow(x,'pending')).join('')||'<div class="alert-empty">Sem pedidos de autorização pendentes.</div>'}
   <details class="alert-device-history"><summary>Dispositivos autorizados (${approved.length})</summary>${approved.map(x=>deviceRow(x,'approved')).join('')||'<div class="alert-empty">Nenhum.</div>'}</details>
   <details class="alert-device-history"><summary>Recusados ou revogados (${history.length})</summary>${history.map(x=>deviceRow(x,'history')).join('')||'<div class="alert-empty">Nenhum.</div>'}</details>
   <p class="alert-security-note">O registo e o ecrã de aprovação são controlos da aplicação. O bloqueio efetivo de pedidos diretos à API exige também validação do dispositivo em todas as Edge Functions e políticas de acesso. Não utilizar esta versão como garantia de segurança até essa integração estar concluída.</p></section></div>`;
   const n=id=>root.querySelector(id);
   n('#alertManualRefresh').onclick=()=>{dirty=false;api.refresh(true)};
   root.querySelectorAll('#alertEnabled,[data-alert-pref],#alertThreshold,#alertBrowser').forEach(el=>el.addEventListener('change',()=>{dirty=true}));
   n('#alertSave').onclick=async()=>{const b=n('#alertSave');b.disabled=true;let data={...prefs};data.enabled=n('#alertEnabled').checked;root.querySelectorAll('[data-alert-pref]').forEach(e=>data[e.dataset.alertPref]=e.checked);data.recurring_late_threshold=+n('#alertThreshold').value;
    data.browser_enabled=n('#alertBrowser').checked;
    if(data.browser_enabled){if(!('Notification' in window)){toast('Este navegador não suporta notificações.','error');b.disabled=false;return}if(Notification.permission!=='granted'){
     const permission=await Notification.requestPermission();if(permission!=='granted'){data.browser_enabled=false;toast('Permissão recusada. Os alertas continuam disponíveis no SILAS.','error')}
    }}
    try{const r=await sb.rpc('worktime_save_alert_preferences',{p_preferences:data});if(r.error)throw r.error;prefs={...prefs,...r.data};dirty=false;toast('Notificações configuradas.','success');api.render(root);drawBadge();}catch(e){toast(e.message,'error');b.disabled=false}
   };
   root.querySelectorAll('[data-alert-read]').forEach(b=>b.onclick=async()=>{b.disabled=true;const r=await sb.rpc('worktime_mark_alert_read',{p_alert_id:b.dataset.alertRead});if(r.error){toast(r.error.message,'error');b.disabled=false;return}reads.add(b.dataset.alertRead);api.render(root);drawBadge()});
   root.querySelectorAll('[data-device-approve],[data-device-reject],[data-device-revoke]').forEach(b=>b.onclick=async()=>{
    const approve=b.hasAttribute('data-device-approve'),revoke=b.hasAttribute('data-device-revoke'),id=b.dataset.deviceApprove||b.dataset.deviceReject||b.dataset.deviceRevoke;
    if((!approve)&&!confirm(revoke?'Revogar o dispositivo?':'Recusar este dispositivo?'))return;
    b.disabled=true;const r=revoke?await sb.rpc('worktime_revoke_device',{p_authorization_id:id}):await sb.rpc('worktime_decide_device',{p_authorization_id:id,p_approve:approve});
    if(r.error){toast(r.error.message,'error');b.disabled=false;return}toast(approve?'Dispositivo autorizado.':revoke?'Autorização revogada.':'Dispositivo recusado.','success');await api.refresh(false)
   });
  }
 };
 function deviceRow(d,kind){const name=getAdmin().users?.find(u=>u.id===d.profile_id)?.name||d.profile_id.slice(0,8);return `<div class="alert-device-row"><span class="alert-device-icon">▣</span><div><strong>${esc(name)}</strong><span>${esc(d.label)}</span><small>Pedido: ${DT(d.requested_at)} · ${kind==='pending'?'A aguardar autorização':d.status==='approved'?'Autorizado':d.status==='rejected'?'Recusado':'Revogado'}</small></div><div class="alert-device-actions">${kind==='pending'?`<button class="btn btn-primary" data-device-approve="${d.id}">Autorizar</button><button class="btn btn-soft" data-device-reject="${d.id}">Recusar</button>`:kind==='approved'?`<button class="btn btn-soft" data-device-revoke="${d.id}">Revogar</button>`:''}</div></div>`}
 function drawBadge(){const b=$('#alertBadge'),n=api.unreadCount(),button=$('#alertBell');if(b){b.textContent=n>99?'99+':String(n);b.classList.toggle('hidden',!n)}if(button)button.setAttribute('aria-label',`Notificações, ${n} por ler`)}
 app=api;return api;
}
window.SilasAlertCenter={checkDevice,create,getDeviceId:deviceId};
})();
