-- CONNECTD Event Tracker: show the tentative programme on the contractor link (#contractor).
-- Run once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run. Safe to run again. Same function as in schema.sql.

create or replace function public.contractor_layout() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('programme', (
    select jsonb_build_object('agenda', coalesce(g.data->'agenda', '[]'::jsonb), 'days', coalesce(g.data->'days', '[]'::jsonb),
                              'updatedAt', g.data->'updatedAt')
    from public.tracker g where g.key = 'programme'),
  'commercial', jsonb_build_object(
    'islands', coalesce(c.data->'islands', '[]'::jsonb),
    'tiers', '[]'::jsonb,
    'partners', coalesce((select jsonb_agg(jsonb_build_object('id', p->'id', 'name', p->'name', 'status', p->'status',
                                                              'island', p->'island', 'booths', p->'booths', 'boothNo', p->'boothNo'))
                          from jsonb_array_elements(c.data->'partners') p where p->>'status' in ('Confirmed', 'Negotiating')), '[]'::jsonb),
    'updatedAt', c.data->'updatedAt'))
  from public.tracker c where c.key = 'commercial';
$$;
grant execute on function public.contractor_layout() to anon, authenticated;
