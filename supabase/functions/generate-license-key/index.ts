// @ts-nocheck
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Generates a random uppercase code XXXX-XXXX
function generateRandomCode(): string {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
  let result = "";
  for (let i = 0; i < 8; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result.substring(0, 4) + "-" + result.substring(4, 8);
}

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { orderID } = await req.json();

    if (!orderID) {
      return new Response(JSON.stringify({ error: "Missing orderID" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Initialize Supabase Client (uses Service Role key to bypass RLS)
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Get PayPal Credentials from Supabase Secrets
    const PAYPAL_CLIENT_ID = Deno.env.get("PAYPAL_CLIENT_ID");
    const PAYPAL_SECRET = Deno.env.get("PAYPAL_SECRET");
    const PAYPAL_ENV = Deno.env.get("PAYPAL_ENV") || "sandbox"; // 'sandbox' or 'live'

    if (!PAYPAL_CLIENT_ID || !PAYPAL_SECRET) {
      throw new Error("Server configuration error: missing PayPal credentials.");
    }

    const apiUrl =
      PAYPAL_ENV === "live"
        ? "https://api-m.paypal.com"
        : "https://api-m.sandbox.paypal.com";

    // 1. Get PayPal Access Token
    const auth = btoa(`${PAYPAL_CLIENT_ID}:${PAYPAL_SECRET}`);
    const tokenResponse = await fetch(`${apiUrl}/v1/oauth2/token`, {
      method: "POST",
      headers: {
        Authorization: `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "grant_type=client_credentials",
    });

    if (!tokenResponse.ok) {
      const errorText = await tokenResponse.text();
      console.error("PayPal Auth Error:", errorText);
      throw new Error("Failed to authenticate with PayPal API");
    }

    const tokenData = await tokenResponse.json();
    const accessToken = tokenData.access_token;

    // 2. Verify the Order
    const orderResponse = await fetch(`${apiUrl}/v2/checkout/orders/${orderID}`, {
      method: "GET",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
      },
    });

    if (!orderResponse.ok) {
      throw new Error("Failed to retrieve PayPal order");
    }

    const orderData = await orderResponse.json();

    console.log(`Order ${orderID} status:`, orderData.status);

    // 3. Ensure order is COMPLETED (or APPROVED if capture happens elsewhere, but standard checkout is COMPLETED after client capture)
    if (orderData.status !== "COMPLETED" && orderData.status !== "APPROVED") {
      return new Response(JSON.stringify({ error: "Order is not completed" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 4. Verify the amount if necessary (e.g., $2.99)
    // Optional check depending on your risk tolerance:
    // const amount = orderData.purchase_units[0].amount.value;
    // if (amount !== "2.99") throw new Error("Invalid payment amount");

    // 5. Check if this orderID was already processed
    const { data: existingCode } = await supabase
      .from("premium_codes")
      .select("*")
      .eq("order_id", orderID)
      .maybeSingle();

    if (existingCode) {
      // If user refreshed the page, return the same code instead of creating a new one
      return new Response(JSON.stringify({ code: existingCode.code }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 6. Generate a unique code
    let licenseCode = generateRandomCode();
    let isUnique = false;
    
    // Ensure uniqueness (simple retry loop)
    for (let i = 0; i < 3; i++) {
        const { data: checkExist } = await supabase.from("premium_codes").select("id").eq("code", licenseCode).maybeSingle();
        if (!checkExist) {
            isUnique = true;
            break;
        }
        licenseCode = generateRandomCode();
    }

    if (!isUnique) throw new Error("Could not generate a unique code. Try again.");

    // 7. Calculate expiration date (30 days from now)
    const expiresAt = new Date();
    expiresAt.setDate(expiresAt.getDate() + 30);

    // 8. Save code to Supabase
    const { error: insertError } = await supabase.from("premium_codes").insert([
      {
        code: licenseCode,
        order_id: orderID,
        expires_at: expiresAt.toISOString(),
      },
    ]);

    if (insertError) {
      console.error("DB Insert Error:", insertError);
      throw new Error("Failed to save license code to database");
    }

    // 9. Return the code back to the client
    return new Response(JSON.stringify({ code: licenseCode }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err: any) {
    console.error("Edge Function Error:", err);
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
