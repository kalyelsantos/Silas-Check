/* SILAS WorkTime — entrada real. Nenhuma conta fictícia é criada aqui. */
(()=>{'use strict';
 const root=document.querySelector('#loginError');
 const showError=(message)=>{
   document.querySelector('#login')?.classList.remove('hidden');
   document.querySelector('#app')?.classList.add('hidden');
   if(root){root.textContent=message;root.classList.remove('hidden')}
 };
 function load(src){return new Promise((resolve,reject)=>{
   const element=document.createElement('script');element.src=src;element.async=false;
   element.onload=()=>resolve();element.onerror=()=>{element.remove();reject(new Error('Falha ao carregar '+src))};
   document.body.append(element);
 })}
 async function fallback(sources,test){let last;
   for(const src of sources){try{await load(src);if(test())return;}catch(e){last=e;console.warn('Fonte indisponível:',src)}}
   throw last||new Error('Biblioteca indisponível');
 }
 async function boot(){
  try{
   const c=window.WORKTIME_CONFIG;
   if(!c?.SUPABASE_URL||!c?.SUPABASE_KEY)throw new Error('Configuração Supabase incompleta');
   await fallback([
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0/dist/umd/supabase.js',
    'https://unpkg.com/@supabase/supabase-js@2.116.0/dist/umd/supabase.js',
    'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.116.0'
   ],()=>!!window.supabase?.createClient);
   try{await fallback([
    'https://cdn.jsdelivr.net/npm/qrcodejs@1.0.0/qrcode.min.js',
    'https://unpkg.com/qrcodejs@1.0.0/qrcode.min.js'
   ],()=>!!window.QRCode)}catch(e){console.warn('QR indisponível: o convite por link continua disponível.',e)}
   await load('assets/js/wines.js?v=2.11.0');
   if(!window.SilasWine?.render)throw Error('Garrafeira indisponível');
   await load('assets/js/alert-center.js?v=2.11.0');
   if(!window.SilasAlertCenter?.create)throw Error('Módulo de alertas indisponível');
   await load('assets/js/app.js?v=2.11.0');
   if(location.protocol==='file:')console.info('WorkTime ligado ao Supabase: o modo de demonstração não está ativo.');
  }catch(error){console.error('SILAS_BOOT_ERROR',error);showError(
    'Não foi possível iniciar o WorkTime real. É necessária ligação à Internet para autenticar. Se persistir, publica esta pasta no teu domínio HTTPS e atualiza a página.'
  )}
 }
 boot();
})();
