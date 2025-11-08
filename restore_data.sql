-- Restore profiles data from backup
-- First, let's update the profiles table to match the backup schema

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS paid BOOLEAN DEFAULT false;
ALTER TABLE profiles ALTER COLUMN dietary_restriction TYPE TEXT;

-- Insert the user data from backup
INSERT INTO profiles (id, updated_at, name, avatar_url, dietary_restriction, paid) VALUES
('46616c15-1934-4d56-8503-e787eeb210f1', NULL, 'Dj', NULL, '["Diabetic"]', false),
('45d1b242-c657-406a-a026-d3134f2bc595', '2024-05-23 05:34:30.973+00', 'Tobi Balogun', NULL, '["Diabetic"]', false),
('914457d0-ff51-4a1a-b747-b67cec014704', NULL, 'Keisha', NULL, '[]', false),
('b5b13a55-edbe-4587-a427-98cbdcd38492', NULL, 'Tamilore', NULL, '[]', false),
('868212f7-5560-4386-8274-5fd6abbe02d6', NULL, 'Brian', NULL, '[]', false),
('91f75dce-8ad2-4869-a812-72d239246187', NULL, 'KTM', NULL, '[]', false),
('5f8ad736-5f57-46f0-a489-183c40d4756d', NULL, 'Akeem', NULL, '[]', false),
('d792787d-e00c-4446-b4fe-c6d5ae27d8a2', NULL, NULL, NULL, 'None', false),
('4ed92b96-5e36-49a9-9963-c64c47f999a0', NULL, 'CUE', NULL, '["Vegetarian","Lactose Intolerant"]', true)
ON CONFLICT (id) DO UPDATE SET
  updated_at = EXCLUDED.updated_at,
  name = EXCLUDED.name,
  avatar_url = EXCLUDED.avatar_url,
  dietary_restriction = EXCLUDED.dietary_restriction,
  paid = EXCLUDED.paid;
