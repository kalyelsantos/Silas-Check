-- OPCIONAL: executar apenas se a extensão pg_cron estiver ativa e validada em staging.
-- Atualiza os alertas de assiduidade mesmo quando a Katia não tem o site aberto.
create extension if not exists pg_cron with schema pg_catalog;
select cron.schedule('silas-worktime-alert-scan','*/10 * * * *',
  'select public.worktime_scan_attendance_alerts();');
-- Para desativar: select cron.unschedule('silas-worktime-alert-scan');
