-- Function to strip non-digit characters (except +) from contact phone_jsonb
CREATE OR REPLACE FUNCTION sanitize_phone_numbers()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.phone_jsonb IS NOT NULL THEN
    NEW.phone_jsonb = COALESCE((
      SELECT jsonb_agg(
        jsonb_set(elem, '{number}', to_jsonb(regexp_replace(elem->>'number', '[^0-9+]', '', 'g')))
      )
      FROM jsonb_array_elements(NEW.phone_jsonb) AS elem
    ), '[]'::jsonb);
  END IF;
  RETURN NEW;
END;
$$;

-- Function to strip non-digit characters (except +) from company phone_number
CREATE OR REPLACE FUNCTION sanitize_company_phone_number()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.phone_number IS NOT NULL THEN
    NEW.phone_number = regexp_replace(NEW.phone_number, '[^0-9+]', '', 'g');
  END IF;
  RETURN NEW;
END;
$$;

-- Trigger for contacts (runs between email lowercase and avatar fetch)
CREATE TRIGGER "11_sanitize_contact_phones"
  BEFORE INSERT OR UPDATE ON contacts
  FOR EACH ROW
  EXECUTE FUNCTION sanitize_phone_numbers();

-- Trigger for companies (runs before logo fetch)
CREATE TRIGGER "10_sanitize_company_phone"
  BEFORE INSERT OR UPDATE ON companies
  FOR EACH ROW
  EXECUTE FUNCTION sanitize_company_phone_number();

-- Backfill existing contact phone numbers
UPDATE contacts
SET phone_jsonb = COALESCE((
  SELECT jsonb_agg(
    jsonb_set(elem, '{number}', to_jsonb(regexp_replace(elem->>'number', '[^0-9+]', '', 'g')))
  )
  FROM jsonb_array_elements(phone_jsonb) AS elem
), '[]'::jsonb)
WHERE phone_jsonb IS NOT NULL;

-- Backfill existing company phone numbers
UPDATE companies
SET phone_number = regexp_replace(phone_number, '[^0-9+]', '', 'g')
WHERE phone_number IS NOT NULL;
