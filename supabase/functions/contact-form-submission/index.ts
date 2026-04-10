// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { supabaseAdmin } from "../_shared/supabaseAdmin.ts";

const CONTACT_FORM_TAG_NAME = "contact-form";
const CONTACT_FORM_TAG_COLOR = "#f9f9f9";

type ContactFormPayload = {
  name?: unknown;
  email?: unknown;
  phone?: unknown;
  message?: unknown;
};

const jsonResponse = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method Not Allowed" }, 405);
  }

  let payload: ContactFormPayload;
  try {
    payload = await parseRequestBody(req);
  } catch (_error) {
    return jsonResponse({ error: "Invalid request body" }, 400);
  }

  const name = typeof payload.name === "string" ? payload.name.trim() : "";
  const email = typeof payload.email === "string" ? payload.email.trim() : "";
  const phone = typeof payload.phone === "string" ? payload.phone.trim() : "";
  const message =
    typeof payload.message === "string" ? payload.message.trim() : "";

  if (!name || !email) {
    return jsonResponse(
      { error: "Missing required fields: name and email" },
      400,
    );
  }

  // Resolve the "contact-form" tag (find existing or create it)
  const tagId = await getOrCreateContactFormTag();
  if (tagId == null) {
    return jsonResponse({ error: "Failed to resolve contact-form tag" }, 500);
  }

  const email_jsonb = [{ email, type: "Work" }];
  const phone_jsonb = phone ? [{ number: phone, type: "Work" }] : [];
  const background = message
    ? `Message from form submission: ${message}`
    : null;
  const nowIso = new Date().toISOString();

  const { data: inserted, error: insertError } = await supabaseAdmin
    .from("contacts")
    .insert({
      name,
      email_jsonb,
      phone_jsonb,
      background,
      tags: [tagId],
      first_seen: nowIso,
      last_seen: nowIso,
    })
    .select("id")
    .single();

  if (insertError) {
    console.error("Failed to insert contact from form submission", insertError);
    return jsonResponse({ error: "Failed to create contact" }, 500);
  }

  return jsonResponse({ success: true, id: inserted?.id }, 201);
});

const parseRequestBody = async (req: Request): Promise<ContactFormPayload> => {
  const contentType = (req.headers.get("content-type") || "").toLowerCase();

  if (contentType.includes("application/json")) {
    return (await req.json()) as ContactFormPayload;
  }

  if (
    contentType.includes("multipart/form-data") ||
    contentType.includes("application/x-www-form-urlencoded")
  ) {
    const formData = await req.formData();
    const result: Record<string, string> = {};
    for (const [key, value] of formData.entries()) {
      if (typeof value === "string") {
        result[key] = value;
      }
    }
    return result as ContactFormPayload;
  }

  // Fallback: try JSON parsing of the raw text body
  const text = await req.text();
  if (!text) return {};
  return JSON.parse(text) as ContactFormPayload;
};

const getOrCreateContactFormTag = async (): Promise<number | null> => {
  const { data: existing, error: selectError } = await supabaseAdmin
    .from("tags")
    .select("id")
    .eq("name", CONTACT_FORM_TAG_NAME)
    .maybeSingle();

  if (selectError) {
    console.error("Failed to look up contact-form tag", selectError);
    return null;
  }

  if (existing?.id != null) {
    return existing.id as number;
  }

  const { data: created, error: insertError } = await supabaseAdmin
    .from("tags")
    .insert({ name: CONTACT_FORM_TAG_NAME, color: CONTACT_FORM_TAG_COLOR })
    .select("id")
    .single();

  if (insertError) {
    console.error("Failed to create contact-form tag", insertError);
    return null;
  }

  return (created?.id as number) ?? null;
};

/* To invoke locally:
  1. Run `make start`
  2. In another terminal, run `make start-supabase-functions`
  3. In another terminal, make an HTTP request:
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/contact-form-submission' \
    --header 'Content-Type: application/json' \
    --data '{
      "name": "Jane Doe",
      "email": "jane.doe@example.com",
      "phone": "+1 555 123 4567",
      "message": "Hi, I would like to learn more about your product."
    }'
*/
