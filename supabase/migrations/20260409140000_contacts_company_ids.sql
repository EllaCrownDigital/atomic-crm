-- Migrate contacts from single company_id to multiple company_ids (array)

-- 1. Drop dependent views and functions
DROP VIEW IF EXISTS public.contacts_summary;
DROP VIEW IF EXISTS public.companies_summary;
DROP VIEW IF EXISTS public.activity_log;
DROP FUNCTION IF EXISTS public.merge_contacts(bigint, bigint);

-- 2. Add new column and populate from existing data
ALTER TABLE public.contacts ADD COLUMN company_ids bigint[] DEFAULT '{}';
UPDATE public.contacts SET company_ids = CASE WHEN company_id IS NOT NULL THEN ARRAY[company_id] ELSE '{}' END;

-- 3. Drop old FK constraint, column, and index
ALTER TABLE public.contacts DROP CONSTRAINT IF EXISTS contacts_company_id_fkey;
DROP INDEX IF EXISTS contacts_company_id_idx;
ALTER TABLE public.contacts DROP COLUMN company_id;

-- 4. Create GIN index for array containment queries
CREATE INDEX contacts_company_ids_idx ON public.contacts USING gin (company_ids);

-- 5. Recreate activity_log view (using company_ids[1] for backward compat)
CREATE OR REPLACE VIEW public.activity_log WITH (security_invoker = on) AS
SELECT
    ('company.' || c.id || '.created') AS id,
    'company.created' AS type,
    c.created_at AS date,
    c.id AS company_id,
    c.sales_id,
    to_json(c.*) AS company,
    NULL::json AS contact,
    NULL::json AS deal,
    NULL::json AS contact_note,
    NULL::json AS deal_note
FROM public.companies c
UNION ALL
SELECT
    ('contact.' || co.id || '.created') AS id,
    'contact.created' AS type,
    co.first_seen AS date,
    co.company_ids[1] AS company_id,
    co.sales_id,
    NULL::json AS company,
    to_json(co.*) AS contact,
    NULL::json AS deal,
    NULL::json AS contact_note,
    NULL::json AS deal_note
FROM public.contacts co
UNION ALL
SELECT
    ('contactNote.' || cn.id || '.created') AS id,
    'contactNote.created' AS type,
    cn.date,
    co.company_ids[1] AS company_id,
    cn.sales_id,
    NULL::json AS company,
    NULL::json AS contact,
    NULL::json AS deal,
    to_json(cn.*) AS contact_note,
    NULL::json AS deal_note
FROM public.contact_notes cn
    LEFT JOIN public.contacts co ON co.id = cn.contact_id
UNION ALL
SELECT
    ('deal.' || d.id || '.created') AS id,
    'deal.created' AS type,
    d.created_at AS date,
    d.company_id,
    d.sales_id,
    NULL::json AS company,
    NULL::json AS contact,
    to_json(d.*) AS deal,
    NULL::json AS contact_note,
    NULL::json AS deal_note
FROM public.deals d
UNION ALL
SELECT
    ('dealNote.' || dn.id || '.created') AS id,
    'dealNote.created' AS type,
    dn.date,
    d.company_id,
    dn.sales_id,
    NULL::json AS company,
    NULL::json AS contact,
    NULL::json AS deal,
    NULL::json AS contact_note,
    to_json(dn.*) AS deal_note
FROM public.deal_notes dn
    LEFT JOIN public.deals d ON d.id = dn.deal_id;

-- 6. Recreate companies_summary view
CREATE OR REPLACE VIEW public.companies_summary WITH (security_invoker = on) AS
SELECT
    c.id,
    c.created_at,
    c.name,
    c.sector,
    c.size,
    c.linkedin_url,
    c.website,
    c.phone_number,
    c.address,
    c.zipcode,
    c.city,
    c.state_abbr,
    c.sales_id,
    c.context_links,
    c.country,
    c.description,
    c.revenue,
    c.tax_identifier,
    c.logo,
    count(DISTINCT d.id) AS nb_deals,
    count(DISTINCT co.id) AS nb_contacts
FROM public.companies c
    LEFT JOIN public.deals d ON c.id = d.company_id
    LEFT JOIN public.contacts co ON c.id = ANY(co.company_ids)
GROUP BY c.id;

-- 7. Recreate contacts_summary view
CREATE OR REPLACE VIEW public.contacts_summary WITH (security_invoker = on) AS
SELECT
    co.id,
    co.name,
    co.gender,
    co.title,
    co.background,
    co.avatar,
    co.first_seen,
    co.last_seen,
    co.has_newsletter,
    co.status,
    co.tags,
    co.company_ids,
    co.sales_id,
    co.linkedin_url,
    co.email_jsonb,
    co.phone_jsonb,
    (jsonb_path_query_array(co.email_jsonb, '$[*]."email"'))::text AS email_fts,
    (jsonb_path_query_array(co.phone_jsonb, '$[*]."number"'))::text AS phone_fts,
    string_agg(DISTINCT c.name, ', ') AS company_name,
    count(DISTINCT t.id) FILTER (WHERE t.done_date IS NULL) AS nb_tasks
FROM public.contacts co
    LEFT JOIN public.tasks t ON co.id = t.contact_id
    LEFT JOIN public.companies c ON c.id = ANY(co.company_ids)
GROUP BY co.id;

-- 8. Recreate merge_contacts function
CREATE OR REPLACE FUNCTION "public"."merge_contacts"("loser_id" bigint, "winner_id" bigint) RETURNS bigint
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  winner_contact contacts%ROWTYPE;
  loser_contact contacts%ROWTYPE;
  deal_record RECORD;
  merged_emails jsonb;
  merged_phones jsonb;
  merged_tags bigint[];
  winner_emails jsonb;
  loser_emails jsonb;
  winner_phones jsonb;
  loser_phones jsonb;
  email_map jsonb;
  phone_map jsonb;
BEGIN
  SELECT * INTO winner_contact FROM contacts WHERE id = winner_id;
  SELECT * INTO loser_contact FROM contacts WHERE id = loser_id;

  IF winner_contact IS NULL OR loser_contact IS NULL THEN
    RAISE EXCEPTION 'Contact not found';
  END IF;

  UPDATE tasks SET contact_id = winner_id WHERE contact_id = loser_id;
  UPDATE contact_notes SET contact_id = winner_id WHERE contact_id = loser_id;

  FOR deal_record IN
    SELECT id, contact_ids FROM deals WHERE contact_ids @> ARRAY[loser_id]
  LOOP
    UPDATE deals
    SET contact_ids = (
      SELECT ARRAY(SELECT DISTINCT unnest(array_remove(deal_record.contact_ids, loser_id) || ARRAY[winner_id]))
    )
    WHERE id = deal_record.id;
  END LOOP;

  winner_emails := COALESCE(winner_contact.email_jsonb, '[]'::jsonb);
  loser_emails := COALESCE(loser_contact.email_jsonb, '[]'::jsonb);
  email_map := '{}'::jsonb;
  IF jsonb_array_length(winner_emails) > 0 THEN
    FOR i IN 0..jsonb_array_length(winner_emails)-1 LOOP
      email_map := email_map || jsonb_build_object(winner_emails->i->>'email', winner_emails->i);
    END LOOP;
  END IF;
  IF jsonb_array_length(loser_emails) > 0 THEN
    FOR i IN 0..jsonb_array_length(loser_emails)-1 LOOP
      IF NOT email_map ? (loser_emails->i->>'email') THEN
        email_map := email_map || jsonb_build_object(loser_emails->i->>'email', loser_emails->i);
      END IF;
    END LOOP;
  END IF;
  merged_emails := COALESCE((SELECT jsonb_agg(value) FROM jsonb_each(email_map)), '[]'::jsonb);

  winner_phones := COALESCE(winner_contact.phone_jsonb, '[]'::jsonb);
  loser_phones := COALESCE(loser_contact.phone_jsonb, '[]'::jsonb);
  phone_map := '{}'::jsonb;
  IF jsonb_array_length(winner_phones) > 0 THEN
    FOR i IN 0..jsonb_array_length(winner_phones)-1 LOOP
      phone_map := phone_map || jsonb_build_object(winner_phones->i->>'number', winner_phones->i);
    END LOOP;
  END IF;
  IF jsonb_array_length(loser_phones) > 0 THEN
    FOR i IN 0..jsonb_array_length(loser_phones)-1 LOOP
      IF NOT phone_map ? (loser_phones->i->>'number') THEN
        phone_map := phone_map || jsonb_build_object(loser_phones->i->>'number', loser_phones->i);
      END IF;
    END LOOP;
  END IF;
  merged_phones := COALESCE((SELECT jsonb_agg(value) FROM jsonb_each(phone_map)), '[]'::jsonb);

  merged_tags := ARRAY(
    SELECT DISTINCT unnest(
      COALESCE(winner_contact.tags, ARRAY[]::bigint[]) ||
      COALESCE(loser_contact.tags, ARRAY[]::bigint[])
    )
  );

  UPDATE contacts SET
    avatar = COALESCE(winner_contact.avatar, loser_contact.avatar),
    gender = COALESCE(winner_contact.gender, loser_contact.gender),
    name = COALESCE(winner_contact.name, loser_contact.name),
    title = COALESCE(winner_contact.title, loser_contact.title),
    company_ids = ARRAY(
      SELECT DISTINCT unnest(
        COALESCE(winner_contact.company_ids, ARRAY[]::bigint[]) ||
        COALESCE(loser_contact.company_ids, ARRAY[]::bigint[])
      )
    ),
    email_jsonb = merged_emails,
    phone_jsonb = merged_phones,
    linkedin_url = COALESCE(winner_contact.linkedin_url, loser_contact.linkedin_url),
    background = COALESCE(winner_contact.background, loser_contact.background),
    has_newsletter = COALESCE(winner_contact.has_newsletter, loser_contact.has_newsletter),
    first_seen = LEAST(COALESCE(winner_contact.first_seen, loser_contact.first_seen), COALESCE(loser_contact.first_seen, winner_contact.first_seen)),
    last_seen = GREATEST(COALESCE(winner_contact.last_seen, loser_contact.last_seen), COALESCE(loser_contact.last_seen, winner_contact.last_seen)),
    sales_id = COALESCE(winner_contact.sales_id, loser_contact.sales_id),
    tags = merged_tags
  WHERE id = winner_id;

  DELETE FROM contacts WHERE id = loser_id;
  RETURN winner_id;
END;
$$;
