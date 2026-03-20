#!/usr/bin/env python3
"""
Script to upload all storage files from backup to new Supabase project
"""
import os
import requests
import json
from pathlib import Path

# Supabase configuration
SUPABASE_URL = os.getenv("SUPABASE_URL", "https://ztqptjimmcdoriefkqcx.supabase.co")
SERVICE_ROLE_KEY = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")

# Backup directory
BACKUP_DIR = Path("sb_backup/kmvqftoebsmmkhxrgdye")

def create_bucket(bucket_name):
    """Create a storage bucket"""
    url = f"{SUPABASE_URL}/storage/v1/bucket"
    headers = {
        "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
        "Content-Type": "application/json"
    }
    data = {
        "id": bucket_name,
        "name": bucket_name,
        "public": True,
        "file_size_limit": 52428800,  # 50MB
        "allowed_mime_types": ["image/*"]
    }
    
    response = requests.post(url, headers=headers, json=data)
    if response.status_code in [200, 201]:
        print(f"✅ Created bucket: {bucket_name}")
    elif response.status_code == 409:
        print(f"ℹ️  Bucket already exists: {bucket_name}")
    else:
        print(f"❌ Failed to create bucket {bucket_name}: {response.text}")

def upload_file(bucket_name, file_path, object_name):
    """Upload a file to Supabase storage"""
    url = f"{SUPABASE_URL}/storage/v1/object/{bucket_name}/{object_name}"
    headers = {
        "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    }
    
    # Determine content type based on file extension
    content_type = "image/jpeg"
    if str(file_path).lower().endswith(('.jpg', '.jpeg')):
        content_type = "image/jpeg"
    elif str(file_path).lower().endswith('.png'):
        content_type = "image/png"
    
    try:
        with open(file_path, 'rb') as f:
            files = {'file': (object_name, f, content_type)}
            response = requests.post(url, headers=headers, files=files)
            
        if response.status_code in [200, 201]:
            return True
        else:
            print(f"❌ Failed to upload {object_name}: {response.text}")
            return False
    except Exception as e:
        print(f"❌ Error uploading {object_name}: {str(e)}")
        return False

def main():
    print("🚀 Starting Supabase storage restoration...")

    if not SERVICE_ROLE_KEY:
        raise RuntimeError("SUPABASE_SERVICE_ROLE_KEY is required for storage uploads.")
    
    # Create buckets
    buckets = ["inventory_images", "recipe_images", "calorie_images2", "pantry_images"]
    for bucket in buckets:
        create_bucket(bucket)
    
    print("\n📁 Uploading files...")
    
    total_files = 0
    uploaded_files = 0
    
    # Upload files from each bucket directory
    for bucket_dir in BACKUP_DIR.iterdir():
        if bucket_dir.is_dir():
            bucket_name = bucket_dir.name
            print(f"\n📂 Processing bucket: {bucket_name}")
            
            for file_path in bucket_dir.rglob("*"):
                if file_path.is_file():
                    # Create object path (preserve directory structure)
                    relative_path = file_path.relative_to(bucket_dir)
                    object_name = str(relative_path)
                    
                    total_files += 1
                    if upload_file(bucket_name, file_path, object_name):
                        uploaded_files += 1
                        if uploaded_files % 10 == 0:
                            print(f"   Uploaded {uploaded_files}/{total_files} files...")
    
    print(f"\n✅ Upload complete! {uploaded_files}/{total_files} files uploaded successfully.")

if __name__ == "__main__":
    main()
