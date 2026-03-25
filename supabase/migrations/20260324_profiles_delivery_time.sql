ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS delivery_time_minutes INTEGER;
