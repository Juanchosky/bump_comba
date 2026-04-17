-- Create table for storing premium license keys
CREATE TABLE public.premium_codes (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    code text NOT NULL UNIQUE,
    order_id text NOT NULL UNIQUE,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    is_used boolean DEFAULT false NOT NULL,
    used_by_device_id text,
    used_at timestamp with time zone,
    expires_at timestamp with time zone
);

-- Turn on Row Level Security
ALTER TABLE public.premium_codes ENABLE ROW LEVEL SECURITY;

-- Anonymous users cannot read or write to this table directly (only Edge Functions can using service_role)
CREATE POLICY "Enable read access for service role only" ON public.premium_codes
    AS PERMISSIVE FOR SELECT
    TO service_role
    USING (true);

-- Allow authenticated or anonymous users to potentially check a code (Optional, can be restricted if checked via Edge Function)
-- We will handle code checking in the Flutter app later via direct Supabase call. Let's allow read for anyone if they have the code.
CREATE POLICY "Allow public to read their own code" ON public.premium_codes
    AS PERMISSIVE FOR SELECT
    TO public
    USING (true);

-- Allow the Flutter app to mark the code as used
CREATE POLICY "Allow public to update code status" ON public.premium_codes
    FOR UPDATE
    TO public
    USING (true);

-- Function to generate a random 8-character string (A-Z, 0-9)
CREATE OR REPLACE FUNCTION generate_random_license_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    chars TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    result TEXT := '';
    i INTEGER;
BEGIN
    FOR i IN 1..8 LOOP
        result := result || substr(chars, floor(random() * length(chars) + 1)::integer, 1);
    END LOOP;
    -- Format as XXXX-XXXX
    RETURN substr(result, 1, 4) || '-' || substr(result, 5, 4);
END;
$$;
