# SILAS WorkTime — validação de dispositivos no backend (obrigatória antes de produção)

O frontend inclui `deviceId` no corpo JSON das chamadas às Edge Functions a partir desta versão (sem adicionar cabeçalhos de CORS). A tabela `worktime_device_authorizations` guarda a aprovação da Katia. Isto **não** torna o identificador do browser uma prova criptográfica de posse, nem obriga o backend a respeitá-lo.

Antes de usar os dispositivos como controlo de acesso efetivo, rever e alterar as Edge Functions existentes `worktime-punch` e `worktime-actions`, bem como qualquer futura função capaz de ler ou escrever dados privilegiados:

1. Validar o JWT com `auth.getUser()`, procurar o perfil **ativo** e a organização no servidor (fluxo que as funções atuais já têm).
2. Ler `body.deviceId` do JSON validado no servidor e verificar UUID válido. Para perfis não administrativos, consultar **no servidor** `worktime_device_authorizations` com `profile_id` do JWT validado, `organization_id` e `status='approved'`. Rejeitar 403 se ausente, pendente, recusado ou revogado.
3. Colocar esta verificação antes de **todas** as mutações, incluindo criar/alterar picagens, correções, tarefas e gestão de vinhos se expostas ao utilizador; incluir também qualquer endpoint de leitura de informação protegida. Rever acessos diretos às tabelas por PostgREST, views, RPCs, Realtime e RLS. Fazer a validação apenas nas Edge Functions não protege acessos diretos.
4. Não confiar no `profile_id`, `role`, `organization_id`, `user_metadata` ou `status` fornecidos pelo cliente. Usar apenas perfil associado a `auth.uid()` e dados armazenados no servidor.
5. Para resistência a clonagem/spoofing, substituir gradualmente o UUID enviado pelo browser por uma prova de posse de chave não exportável (WebCrypto), com desafio/assinatura validada no servidor e anti-replay; considerar autenticação forte para administradores.
6. Se os clientes perderem armazenamento local, tratar a instalação como novo dispositivo e reaprovar. Prever revogação e registo de auditoria no servidor.
7. Para alterações de palavra-passe com revogação imediata de sessões, analisar encerramento das sessões Auth antigas e/ou checks de session_id no backend. A alteração da palavra-passe, por si só, não prova que um JWT já emitido deixa imediatamente de funcionar.

Exemplo **ilustrativo** de verificação em cada Edge Function (requer adaptação à função real, antes de colocar em produção):

```ts
const id = String(body.deviceId ?? '');
if (profile.role !== 'admin') {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return bad('Dispositivo não autorizado.', 403);
  const { data, error } = await admin.from('worktime_device_authorizations')
    .select('id')
    .eq('organization_id', profile.organization_id)
    .eq('profile_id', profile.id)
    .eq('device_id', id)
    .eq('status', 'approved')
    .maybeSingle();
  if (error || !data) return bad('Aguardar autorização da administração.', 403);
}
```

Esta verificação é uma melhoria operacional, mas ainda admite falsificação por quem obtenha um identificador aprovado. Não confundir com autenticação de dispositivo forte.

**Não alterar automaticamente as Edge Functions de produção sem testes de regressão**: são usadas nas picagens reais e erros podem impedir entradas e saídas.
