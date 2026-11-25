-- =====================================================================
-- SCHEMA POSTGRESQL & POSTGIS — MANGEOÙ ? (SUPABASE)
-- Architecture de Géolocalisation Hyper-locale & Cloisonnement RLS
-- =====================================================================

-- 1. Activation de l'extension spatiale PostGIS
CREATE EXTENSION IF NOT EXISTS postgis;

-- 2. Types Énumérés
CREATE TYPE user_role AS ENUM ('public', 'vendeur', 'admin');
CREATE TYPE stall_status AS ENUM ('en_service', 'ferme');
CREATE TYPE dish_category AS ENUM ('sale', 'sucre');

-- ---------------------------------------------------------------------
-- 3. Table des Profils Utilisateurs (Liée à auth.users de Supabase)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role user_role NOT NULL DEFAULT 'public',
  full_name TEXT,
  phone_number TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Sécurité RLS Profiles
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

-- Helper sécurisé pour vérifier le rôle admin sans récursion RLS (SECURITY DEFINER)
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- Policies RLS Profiles
CREATE POLICY "Les utilisateurs peuvent lire leur propre profil"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Les utilisateurs peuvent mettre a jour leur propre profil"
  ON public.profiles FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Les administrateurs ont plein acces aux profils"
  ON public.profiles FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- Trigger automatique de création de profil lors de l'inscription auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name, role)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
    COALESCE((NEW.raw_user_meta_data->>'role')::public.user_role, 'public'::public.user_role)
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ---------------------------------------------------------------------
-- 4. Table des Étals Vendeurs (Stalls) avec Coordonnées Spatiales PostGIS
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stalls (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  commune TEXT NOT NULL,
  quarter TEXT NOT NULL,
  description TEXT,
  image_url TEXT,
  
  -- Coordonnées géographiques PostGIS (WGS 84 SRID 4326)
  location GEOGRAPHY(Point, 4326) NOT NULL,
  
  -- Statut en direct réactif (En service / Fermé)
  status stall_status NOT NULL DEFAULT 'ferme',
  last_status_change TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  -- Spécialité et fourchette de prix
  specialty_title TEXT NOT NULL,
  price_min_fcfa INTEGER NOT NULL DEFAULT 500,
  price_max_fcfa INTEGER NOT NULL DEFAULT 1500,
  opening_hours TEXT DEFAULT '11h00 - 23h00',
  
  -- Métadonnées & Visibilité
  is_verified BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index spatial GiST pour des requêtes de distance ultra-rapides (< 5ms)
CREATE INDEX IF NOT EXISTS idx_stalls_location ON public.stalls USING GIST(location);
CREATE INDEX IF NOT EXISTS idx_stalls_status ON public.stalls(status);
CREATE INDEX IF NOT EXISTS idx_stalls_commune ON public.stalls(commune);

-- Sécurité RLS Stalls (Cloisonnement Strict)
ALTER TABLE public.stalls ENABLE ROW LEVEL SECURITY;

-- Règle Public : Tout le monde peut voir les étals actifs
CREATE POLICY "Lecture publique des étals"
  ON public.stalls FOR SELECT
  USING (is_verified = true);

-- Règle Vendeur : Le vendeur ne peut modifier QUE son propre étal
CREATE POLICY "Vendeur gère son propre étal"
  ON public.stalls FOR UPDATE
  USING (seller_id = auth.uid())
  WITH CHECK (seller_id = auth.uid());

CREATE POLICY "Vendeur peut insérer son étal"
  ON public.stalls FOR INSERT
  WITH CHECK (seller_id = auth.uid());

-- Règle Admin : Accès panoptique complet (utilisant is_admin() pour éviter la récursion)
CREATE POLICY "Admin a plein accès aux étals"
  ON public.stalls FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------
-- 5. Catalogue Officiel des Spécialités d'Abidjan
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.dishes (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  category dish_category NOT NULL DEFAULT 'sale',
  family TEXT NOT NULL,
  default_price_range TEXT NOT NULL,
  description TEXT NOT NULL,
  image_url TEXT,
  keywords TEXT[] NOT NULL DEFAULT '{}',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.dishes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Catalogue public en lecture seule"
  ON public.dishes FOR SELECT
  USING (true);

CREATE POLICY "Admin peut gérer les spécialités du catalogue"
  ON public.dishes FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------
-- 6. Régie Publicitaire & Minuteur Sponsors B2B
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.ad_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sponsor_name TEXT NOT NULL,
  campaign_title TEXT NOT NULL,
  banner_url TEXT,
  target_url TEXT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  click_count INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.ad_campaigns ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Lecture publique des pubs actives"
  ON public.ad_campaigns FOR SELECT
  USING (is_active = true AND NOW() BETWEEN starts_at AND ends_at);

CREATE POLICY "Admin gère les campagnes de pub"
  ON public.ad_campaigns FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ---------------------------------------------------------------------
-- 7. Statistiques & Télémétrie des Recherches par Quartier
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.search_logs (
  id BIGSERIAL PRIMARY KEY,
  query TEXT,
  commune TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.search_logs ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Insertion publique anonyme des logs de recherche"
  ON public.search_logs FOR INSERT
  WITH CHECK (true);

CREATE POLICY "Admin consulte les statistiques de recherche"
  ON public.search_logs FOR SELECT
  USING (public.is_admin());

-- ---------------------------------------------------------------------
-- 8. Configuration Supabase Storage & RLS des Images d'Étals
-- ---------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'stalls_images', 
  'stalls_images', 
  true, 
  5242880, -- Limite de 5 Mo par image
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/jfif']
)
ON CONFLICT (id) DO UPDATE SET 
  public = true,
  file_size_limit = 5242880,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/jfif'];

-- Policies RLS pour les objets du bucket stalls_images
CREATE POLICY "Lecture publique des photos d'étals"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'stalls_images');

CREATE POLICY "Vendeurs et admins peuvent uploader des photos"
  ON storage.objects FOR INSERT
  WITH CHECK (
    bucket_id = 'stalls_images'
    AND (
      auth.role() = 'authenticated'
      OR public.is_admin()
    )
  );

CREATE POLICY "Vendeurs gèrent leurs propres photos ou admin"
  ON storage.objects FOR UPDATE
  USING (
    bucket_id = 'stalls_images'
    AND (
      auth.uid()::text = (storage.foldername(name))[1]
      OR public.is_admin()
    )
  );

CREATE POLICY "Suppression autorisée pour propriétaire ou admin"
  ON storage.objects FOR DELETE
  USING (
    bucket_id = 'stalls_images'
    AND (
      auth.uid()::text = (storage.foldername(name))[1]
      OR public.is_admin()
    )
  );

-- ---------------------------------------------------------------------
-- 9. FONCTION RPC SPATIALE : RECHERCHE DES ÉTALS AUTOUR DU CLIENT
-- Calcule la distance exacte en mètres avec ST_Distance (PostGIS)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_nearby_stalls(
  user_lat DOUBLE PRECISION,
  user_lng DOUBLE PRECISION,
  radius_meters DOUBLE PRECISION DEFAULT 10000,
  only_live BOOLEAN DEFAULT true,
  search_filter TEXT DEFAULT NULL
)
RETURNS TABLE (
  id UUID,
  name TEXT,
  commune TEXT,
  quarter TEXT,
  specialty_title TEXT,
  status stall_status,
  price_min_fcfa INTEGER,
  price_max_fcfa INTEGER,
  opening_hours TEXT,
  image_url TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  distance_meters DOUBLE PRECISION
)
LANGUAGE sql
STABLE
AS $$
  SELECT 
    s.id,
    s.name,
    s.commune,
    s.quarter,
    s.specialty_title,
    s.status,
    s.price_min_fcfa,
    s.price_max_fcfa,
    s.opening_hours,
    s.image_url,
    ST_Y(s.location::geometry) AS lat,
    ST_X(s.location::geometry) AS lng,
    ST_Distance(s.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography) AS distance_meters
  FROM public.stalls s
  WHERE 
    s.is_verified = true
    AND ST_DWithin(s.location, ST_SetSRID(ST_MakePoint(user_lng, user_lat), 4326)::geography, radius_meters)
    AND (NOT only_live OR s.status = 'en_service')
    AND (
      search_filter IS NULL 
      OR s.name ILIKE '%' || search_filter || '%'
      OR s.specialty_title ILIKE '%' || search_filter || '%'
      OR s.commune ILIKE '%' || search_filter || '%'
    )
  ORDER BY distance_meters ASC;
$$;

-- ---------------------------------------------------------------------
-- 10. JEU DE DONNÉES INITIAL (SEED DATA ABIDJAN)
-- ---------------------------------------------------------------------
INSERT INTO public.dishes (id, name, category, family, default_price_range, description, image_url, keywords)
VALUES 
  ('garba', 'Le Garba National', 'sale', 'incontournables', '500 – 1 500 FCFA', 'Attiéké fin, thon frit croustillant, piment rouge frais pilé et dés d''oignons.', 'https://images.unsplash.com/photo-1544025162-d76694265947?auto=format&fit=crop&w=800&q=80', ARRAY['garba', 'attieke', 'thon', 'poisson', 'garbadrome']),
  ('alloco', 'L’Alloco & Piment', 'sale', 'incontournables', '300 – 1 000 FCFA', 'Bananes plantains mûres frites en dés dorés avec sauce pimentée.', 'https://images.unsplash.com/photo-1628294895950-9805252327bc?auto=format&fit=crop&w=800&q=80', ARRAY['alloco', 'aloco', 'banane', 'plantain', 'frit', 'oeuf']),
  ('choukouya', 'Le Choukouya d’Agneau', 'sale', 'braises', '2 000 – 5 000 FCFA', 'Viande marinée et grillée au charbon ardent avec kankankan piquant.', 'https://images.unsplash.com/photo-1544025162-d76694265947?auto=format&fit=crop&w=800&q=80', ARRAY['choukouya', 'agneau', 'mouton', 'kankankan', 'braise']),
  ('pain-brochette', 'Le Pain Brochette ("Pain Bro")', 'sale', 'sandwichs', '500 – 1 500 FCFA', 'Baguette garnie de brochettes de bœuf grillées, crudités et mayonnaise kankankan.', 'https://images.unsplash.com/photo-1509722747041-616f39b57569?auto=format&fit=crop&w=800&q=80', ARRAY['pain', 'brochette', 'pain bro', 'baguette']),
  ('claclo', 'Le Claclo (Klaklo)', 'sucre', 'douceurs', '200 – 500 FCFA', 'Beignets ronds et dorés préparés à partir de bananes plantains très mûres.', 'https://images.unsplash.com/photo-1541544741938-0af808871cc0?auto=format&fit=crop&w=800&q=80', ARRAY['claclo', 'klaklo', 'beignet', 'banane', 'gouter'])
ON CONFLICT (id) DO NOTHING;
