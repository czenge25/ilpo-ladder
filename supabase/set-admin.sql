-- Sign in to your deployed app once, then copy YOUR user UUID from
-- Supabase -> Authentication -> Users. Run this in the SQL Editor.
-- Replace the placeholder. Do not use someone else's UUID.
insert into private.admins(user_id)
values ('REPLACE_WITH_YOUR_AUTH_USER_UUID'::uuid)
on conflict (user_id) do nothing;
