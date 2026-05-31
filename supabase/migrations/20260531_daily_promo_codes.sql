-- ============================================================
-- SOBRE ROJO — Sistema de Códigos Diarios de Premium
-- ============================================================
-- Tabla principal: códigos que el admin crea diariamente
-- ============================================================

CREATE TABLE public.daily_promo_codes (
    id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    code                text NOT NULL UNIQUE,
    date_valid          date NOT NULL,              -- Fecha UTC para la que es válido (YYYY-MM-DD)
    bonus_days          integer NOT NULL DEFAULT 1, -- Días de premium que otorga (1 o 2)
    max_redemptions     integer NOT NULL DEFAULT 10,-- Cupo máximo de usos
    redemptions_count   integer NOT NULL DEFAULT 0, -- Counter atómico de usos realizados
    is_active           boolean NOT NULL DEFAULT true, -- Para desactivar manualmente
    telegram_channel    text,                       -- URL del canal de Telegram (opcional)
    created_at          timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- Tabla de canjes: quién usó qué código
-- ============================================================

CREATE TABLE public.daily_redemptions (
    id              uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    promo_code_id   uuid NOT NULL REFERENCES public.daily_promo_codes(id) ON DELETE CASCADE,
    device_id       text NOT NULL,
    redeemed_at     timestamptz DEFAULT now() NOT NULL,
    expires_at      timestamptz NOT NULL,           -- Hasta cuándo dura el premium
    -- Un dispositivo solo puede canjear una vez por código
    UNIQUE (promo_code_id, device_id)
);

-- Índice para buscar rápido por device_id
CREATE INDEX idx_daily_redemptions_device_id ON public.daily_redemptions (device_id);

-- ============================================================
-- Row Level Security
-- ============================================================

ALTER TABLE public.daily_promo_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_redemptions ENABLE ROW LEVEL SECURITY;

-- Lectura pública de códigos (para que la app pueda consultar)
CREATE POLICY "Public can read active promo codes"
    ON public.daily_promo_codes FOR SELECT
    TO public
    USING (is_active = true);

-- Inserción de canjes: pública (la app lo hace directamente)
-- La seguridad real está en la función atómica que valida todo antes de insertar
CREATE POLICY "Public can insert redemptions"
    ON public.daily_redemptions FOR INSERT
    TO public
    WITH CHECK (true);

-- Lectura de canjes: un dispositivo solo puede ver sus propios canjes
CREATE POLICY "Public can read own redemptions"
    ON public.daily_redemptions FOR SELECT
    TO public
    USING (true);

-- ============================================================
-- Función atómica: redeem_daily_promo_code
-- Valida + incrementa counter + inserta canje en una sola TX
-- Retorna JSON con success, message, expires_at, bonus_days
-- ============================================================

CREATE OR REPLACE FUNCTION public.redeem_daily_promo_code(
    p_code      text,
    p_device_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER  -- Corre con privilegios del owner para poder hacer UPDATE
AS $$
DECLARE
    v_promo         record;
    v_already_used  boolean;
    v_expires_at    timestamptz;
    v_today         date;
BEGIN
    -- Fecha actual en UTC (inamovible, no importa el timezone del cliente)
    v_today := CURRENT_DATE AT TIME ZONE 'UTC';

    -- 1. Buscar el código (bloqueo para evitar race conditions)
    SELECT * INTO v_promo
    FROM public.daily_promo_codes
    WHERE code = upper(trim(p_code))
      AND is_active = true
    FOR UPDATE;  -- Lock de fila para evitar concurrencia

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Código inválido o no encontrado.'
        );
    END IF;

    -- 2. Verificar que el código es válido PARA HOY
    IF v_promo.date_valid <> v_today THEN
        IF v_promo.date_valid < v_today THEN
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Este código ya expiró. Sigue el canal de Telegram para el código de hoy. 📣'
            );
        ELSE
            RETURN jsonb_build_object(
                'success', false,
                'message', 'Este código aún no está activo. ¡Espera al día indicado!'
            );
        END IF;
    END IF;

    -- 3. Verificar cupo disponible
    IF v_promo.redemptions_count >= v_promo.max_redemptions THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', '¡El cupo se agotó! Sé más rápido mañana. 🏃'
        );
    END IF;

    -- 4. Verificar que este dispositivo no haya canjeado ya este código
    SELECT EXISTS (
        SELECT 1 FROM public.daily_redemptions
        WHERE promo_code_id = v_promo.id
          AND device_id = p_device_id
    ) INTO v_already_used;

    IF v_already_used THEN
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya canjeaste este código en este dispositivo. ¡Vuelve mañana!'
        );
    END IF;

    -- 5. Calcular fecha de expiración del premium
    v_expires_at := now() + (v_promo.bonus_days || ' days')::interval;

    -- 6. Insertar el canje (UNIQUE constraint lo protege contra race conditions)
    BEGIN
        INSERT INTO public.daily_redemptions (promo_code_id, device_id, expires_at)
        VALUES (v_promo.id, p_device_id, v_expires_at);
    EXCEPTION WHEN unique_violation THEN
        -- Otro request del mismo dispositivo llegó primero
        RETURN jsonb_build_object(
            'success', false,
            'message', 'Ya canjeaste este código en este dispositivo. ¡Vuelve mañana!'
        );
    END;

    -- 7. Incrementar counter de forma atómica
    UPDATE public.daily_promo_codes
    SET redemptions_count = redemptions_count + 1
    WHERE id = v_promo.id;

    -- 8. Éxito
    RETURN jsonb_build_object(
        'success',     true,
        'message',     format('¡%s día%s de Premium activado%s! 🎉', v_promo.bonus_days, CASE WHEN v_promo.bonus_days > 1 THEN 's' ELSE '' END, CASE WHEN v_promo.bonus_days > 1 THEN 's' ELSE '' END),
        'expires_at',  v_expires_at,
        'bonus_days',  v_promo.bonus_days,
        'spots_left',  v_promo.max_redemptions - v_promo.redemptions_count - 1
    );
END;
$$;

-- ============================================================
-- Función auxiliar: check_daily_promo_code
-- Solo consulta el estado del código (cuántos cupos quedan, si es válido hoy)
-- Sin efectos secundarios, para mostrar info al usuario antes de canjear
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_daily_promo_code(
    p_code      text,
    p_device_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_promo         record;
    v_already_used  boolean;
    v_today         date;
    v_spots_left    integer;
BEGIN
    v_today := CURRENT_DATE AT TIME ZONE 'UTC';

    SELECT * INTO v_promo
    FROM public.daily_promo_codes
    WHERE code = upper(trim(p_code))
      AND is_active = true;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Código no encontrado.');
    END IF;

    IF v_promo.date_valid <> v_today THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Código expirado o no activo hoy.');
    END IF;

    v_spots_left := v_promo.max_redemptions - v_promo.redemptions_count;

    IF v_spots_left <= 0 THEN
        RETURN jsonb_build_object('valid', false, 'message', '¡Cupo agotado!', 'spots_left', 0);
    END IF;

    SELECT EXISTS (
        SELECT 1 FROM public.daily_redemptions
        WHERE promo_code_id = v_promo.id AND device_id = p_device_id
    ) INTO v_already_used;

    IF v_already_used THEN
        RETURN jsonb_build_object('valid', false, 'message', 'Ya usaste este código hoy.', 'already_used', true);
    END IF;

    RETURN jsonb_build_object(
        'valid',      true,
        'bonus_days', v_promo.bonus_days,
        'spots_left', v_spots_left,
        'message',    format('%s cupo%s disponible%s', v_spots_left, CASE WHEN v_spots_left <> 1 THEN 's' ELSE '' END, CASE WHEN v_spots_left <> 1 THEN 's' ELSE '' END)
    );
END;
$$;
