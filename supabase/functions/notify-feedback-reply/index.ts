// TopSafeB private feedback-reply email notification.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405, headers: corsHeaders });
  try {
    const authHeader = req.headers.get("Authorization") || ""; const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : authHeader;
    if (!token) return Response.json({ error: "Sign-in required" }, { status: 401, headers: corsHeaders });
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const brevoKey = Deno.env.get("BREVO_API_KEY");
    const fromEmail = Deno.env.get("TOPSAFEB_FROM_EMAIL");
    if (!serviceKey || !brevoKey || !fromEmail) return Response.json({ error: "Email service not configured" }, { status: 503, headers: corsHeaders });
    const supabase = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: userData, error: userError } = await supabase.auth.getUser(token);
    const user = userData?.user;
    if (userError || !user) return Response.json({ error: "Invalid sign-in" }, { status: 401, headers: corsHeaders });
    const { data: admin, error: adminError } = await supabase.from("admin_users").select("user_id").eq("user_id", user.id).maybeSingle();
    if (adminError || !admin) return Response.json({ error: "Administrator access required" }, { status: 403, headers: corsHeaders });
    const body = await req.json().catch(() => ({}));
    const feedbackId = typeof body.feedbackId === "string" ? body.feedbackId : "";
    if (!feedbackId) return Response.json({ error: "Feedback ID required" }, { status: 400, headers: corsHeaders });
    const { data: feedback, error: feedbackError } = await supabase.from("customer_feedback").select("customer_email,customer_name,owner_reply").eq("id", feedbackId).maybeSingle();
    if (feedbackError || !feedback?.customer_email || !feedback.owner_reply) return Response.json({ error: "Saved reply or customer email not found" }, { status: 404, headers: corsHeaders });
    const dashboardUrl = "https://ebubemichael442-ui.github.io/topsafeb/dashboard.html";
    const greeting = "Hello,";
    const emailPayload = {
      sender: { name: "TopSafeB", email: fromEmail },
      to: [{ email: feedback.customer_email }],
      subject: "You have a new private reply from TopSafeB",
      textContent: [greeting, "", "TopSafeB has sent you a private reply. Sign in to your account to read it:", dashboardUrl, "", "For your privacy, the reply is not included in this email.", "", "TopSafeB — Independent financial education"].join(String.fromCharCode(10)),
      htmlContent: "<p>" + greeting + "</p><p>TopSafeB has sent you a private reply. Sign in to your account to read it:</p><p><a href=\"" + dashboardUrl + "\">Open your TopSafeB dashboard</a></p><p>For your privacy, the reply is not included in this email.</p><p>TopSafeB — Independent financial education</p>"
    };
    const emailResponse = await fetch("https://api.brevo.com/v3/smtp/email", {
      method: "POST",
      headers: { "accept": "application/json", "api-key": brevoKey, "content-type": "application/json" },
      body: JSON.stringify(emailPayload)
    });
    if (!emailResponse.ok) {
      console.error("Brevo send failed", emailResponse.status, await emailResponse.text());
      return Response.json({ error: "Email provider could not send notification" }, { status: 502, headers: corsHeaders });
    }
    return Response.json({ success: true }, { headers: corsHeaders });
  } catch (error) {
    console.error("Feedback notification error", error);
    return Response.json({ error: "Unexpected notification error" }, { status: 500, headers: corsHeaders });
  }
});