-- Complete database restoration script for Ounje app
-- This script restores the profiles table with all user data

-- First, update the profiles table schema to match the backup
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS paid BOOLEAN DEFAULT false;

-- Clear existing data (if any)
TRUNCATE TABLE profiles;

-- Restore all user profiles from backup
INSERT INTO profiles (id, updated_at, name, avatar_url, dietary_restriction, paid) VALUES
('46616c15-1934-4d56-8503-e787eeb210f1', NULL, 'Dj', NULL, '["Diabetic"]', false),
('45d1b242-c657-406a-a026-d3134f2bc595', '2024-05-23 05:34:30.973+00', 'Tobi Balogun', NULL, '["Diabetic"]', false),
('914457d0-ff51-4a1a-b747-b67cec014704', NULL, 'Keisha', NULL, '[]', false),
('b5b13a55-edbe-4587-a427-98cbdcd38492', NULL, 'Tamilore', NULL, '[]', false),
('868212f7-5560-4386-8274-5fd6abbe02d6', NULL, 'Brian', NULL, '[]', false),
('91f75dce-8ad2-4869-a812-72d239246187', NULL, 'KTM', NULL, '[]', false),
('5f8ad736-5f57-46f0-a489-183c40d4756d', NULL, 'Akeem', NULL, '[]', false),
('d792787d-e00c-4446-b4fe-c6d5ae27d8a2', NULL, NULL, NULL, 'None', false),
('4ed92b96-5e36-49a9-9963-c64c47f999a0', NULL, 'CUE', NULL, '["Vegetarian","Lactose Intolerant"]', true),
('e781eaff-63ff-403d-8c9c-5bebf9611505', NULL, 'Dave', NULL, '[]', false),
('1ccd2f64-136e-45ec-8be8-16781014af44', NULL, 'Dave Jaga', NULL, '[]', false);

-- Create storage buckets for the app
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types) VALUES
('inventory_images', 'inventory_images', true, 52428800, '{"image/*"}'),
('recipe_images', 'recipe_images', true, 52428800, '{"image/*"}'),
('calorie_images2', 'calorie_images2', true, 52428800, '{"image/*"}'),
('pantry_images', 'pantry_images', true, 52428800, '{"image/*"}')
ON CONFLICT (id) DO NOTHING;

-- Set up storage policies
CREATE POLICY IF NOT EXISTS "Allow public read access" ON storage.objects FOR SELECT USING (true);
CREATE POLICY IF NOT EXISTS "Allow authenticated users to upload" ON storage.objects FOR INSERT WITH CHECK (auth.role() = 'authenticated');
CREATE POLICY IF NOT EXISTS "Allow users to update own files" ON storage.objects FOR UPDATE USING (auth.uid()::text = (storage.foldername(name))[1]);
CREATE POLICY IF NOT EXISTS "Allow users to delete own files" ON storage.objects FOR DELETE USING (auth.uid()::text = (storage.foldername(name))[1]);

-- Verify the restoration
SELECT 'Profiles restored: ' || count(*) as result FROM profiles;
SELECT 'Storage buckets created: ' || count(*) as result FROM storage.buckets WHERE name IN ('inventory_images', 'recipe_images', 'calorie_images2', 'pantry_images');
