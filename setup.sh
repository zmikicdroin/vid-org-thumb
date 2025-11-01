#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="video-organizer"
VENV_DIR="venv"
PYTHON_BIN="${PYTHON_BIN:-python3}"
PIP_ARGS="--disable-pip-version-check"

echo "🚀 Setting up Video Organizer Flask App..."
echo "==========================================="
echo "Project dir: $PROJECT_DIR"

mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

echo "📁 Creating subdirectories..."
mkdir -p templates static/css static/js uploads thumbnails instance

# Write requirements.txt (with gunicorn for production)
echo "📝 Creating requirements.txt..."
cat > requirements.txt <<'REQEOF'
Flask==3.0.0
Flask-SQLAlchemy==3.1.1
opencv-python-headless==4.8.1.78
Pillow==10.1.0
requests==2.31.0
Werkzeug==3.0.1
numpy<2
gunicorn==21.2.0
REQEOF

# Write Dockerfile
echo "📝 Creating Dockerfile..."
cat > Dockerfile <<'DOCKERFILE'
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies for OpenCV and video processing
RUN apt-get update && apt-get install -y \
    ffmpeg \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for better caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create necessary directories
RUN mkdir -p uploads thumbnails instance

# Expose port
EXPOSE 5000

# Set environment variables
ENV FLASK_APP=app.py
ENV PYTHONUNBUFFERED=1

# Run with gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "4", "--timeout", "120", "app:app"]
DOCKERFILE

# Write docker-compose.yaml
echo "📝 Creating docker-compose.yaml..."
cat > docker-compose.yaml <<'COMPOSE'
version: '3.8'

services:
  web:
    build: .
    container_name: video-organizer
    restart: unless-stopped
    ports:
      - "5000:5000"
    volumes:
      - ./uploads:/app/uploads
      - ./thumbnails:/app/thumbnails
      - ./instance:/app/instance
    environment:
      - FLASK_ENV=production
      - PYTHONUNBUFFERED=1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  uploads:
  thumbnails:
  instance:
COMPOSE

# Write .dockerignore
echo "📝 Creating .dockerignore..."
cat > .dockerignore <<'DOCKERIGNORE'
__pycache__/
*.py[cod]
*$py.class
*.so
.Python

# Virtual environments
env/
venv/
venv*/
ENV/
myenv/
.env
.python-version

# Distribution / packaging
build/
dist/
eggs/
*.egg-info/

# Database (persisted via volume)
*.db
*.sqlite

# Git
.git/
.gitignore

# IDE
.vscode/
.idea/
*.swp
*~

# OS
.DS_Store
Thumbs.db

# Docker
.dockerignore

# Logs
*.log

# Documentation
*.md
DOCKERIGNORE

# Write Coolify configuration
echo "📝 Creating coolify.yaml..."
cat > coolify.yaml <<'COOLIFY'
version: '3.8'

services:
  app:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    environment:
      - FLASK_ENV=production
      - PYTHONUNBUFFERED=1
    volumes:
      - uploads-data:/app/uploads
      - thumbnails-data:/app/thumbnails
      - db-data:/app/instance
    labels:
      - "coolify.managed=true"
      - "coolify.type=application"
      - "coolify.name=video-organizer"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  uploads-data:
    driver: local
  thumbnails-data:
    driver: local
  db-data:
    driver: local
COOLIFY

# Write app.py
echo "📝 Creating app.py..."
cat > app.py <<'PYEOF'
from flask import Flask, render_template, request, redirect, url_for, jsonify, send_from_directory
from flask_sqlalchemy import SQLAlchemy
from datetime import datetime
import os
import cv2
from werkzeug.utils import secure_filename
from PIL import Image
import requests
from io import BytesIO
import re

app = Flask(__name__)

# Configuration
app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get('DATABASE_URL', 'sqlite:///instance/database.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = os.environ.get('UPLOAD_FOLDER', 'uploads')
app.config['THUMBNAIL_FOLDER'] = os.environ.get('THUMBNAIL_FOLDER', 'thumbnails')
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB
app.config['ALLOWED_EXTENSIONS'] = {'mp4', 'avi', 'mov', 'mkv', 'webm', 'flv'}

db = SQLAlchemy(app)

# Ensure directories exist
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
os.makedirs(app.config['THUMBNAIL_FOLDER'], exist_ok=True)
os.makedirs('instance', exist_ok=True)

# Database Models
class Category(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False, unique=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    videos = db.relationship('Video', backref='category', lazy=True)

class Video(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    title = db.Column(db.String(200), nullable=False)
    thumbnail_path = db.Column(db.String(300), nullable=False)
    video_path = db.Column(db.String(300))
    youtube_url = db.Column(db.String(300))
    is_youtube = db.Column(db.Boolean, default=False)
    category_id = db.Column(db.Integer, db.ForeignKey('category.id'), nullable=False)
    upload_date = db.Column(db.DateTime, default=datetime.utcnow)

# Initialize database
with app.app_context():
    db.create_all()

def allowed_file(filename):
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in app.config['ALLOWED_EXTENSIONS']

def extract_video_id(youtube_url):
    """Extract YouTube video ID from URL"""
    patterns = [
        r'(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/embed\/)([a-zA-Z0-9_-]{11})',
        r'youtube\.com\/watch\?.*v=([a-zA-Z0-9_-]{11})',
    ]
    for pattern in patterns:
        match = re.search(pattern, youtube_url)
        if match:
            return match.group(1)
    return None

def get_youtube_title(video_id):
    """Get YouTube video title from oEmbed API"""
    try:
        oembed_url = f'https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v={video_id}&format=json'
        response = requests.get(oembed_url, timeout=10)
        if response.status_code == 200:
            data = response.json()
            return data.get('title', 'YouTube Video')
    except Exception as e:
        print(f"Error fetching YouTube title: {e}")
    return 'YouTube Video'

def extract_youtube_thumbnail(youtube_url):
    """Extract thumbnail from YouTube URL"""
    try:
        video_id = extract_video_id(youtube_url)
        if not video_id:
            return None, None
        
        thumbnail_urls = [
            f'https://img.youtube.com/vi/{video_id}/maxresdefault.jpg',
            f'https://img.youtube.com/vi/{video_id}/sddefault.jpg',
            f'https://img.youtube.com/vi/{video_id}/hqdefault.jpg',
            f'https://img.youtube.com/vi/{video_id}/mqdefault.jpg',
            f'https://img.youtube.com/vi/{video_id}/default.jpg',
        ]
        
        video_title = get_youtube_title(video_id)
        
        for thumb_url in thumbnail_urls:
            try:
                response = requests.get(thumb_url, timeout=10)
                if response.status_code == 200 and len(response.content) > 1000:
                    img = Image.open(BytesIO(response.content)).convert('RGB')
                    timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
                    thumbnail_filename = f'yt_{video_id}_{timestamp}.jpg'
                    thumbnail_path = os.path.join(app.config['THUMBNAIL_FOLDER'], thumbnail_filename)
                    img.save(thumbnail_path, 'JPEG', quality=85)
                    return thumbnail_filename, video_title
            except Exception:
                continue
        
        return None, video_title
    except Exception as e:
        print(f"Error extracting YouTube thumbnail: {e}")
        return None, None

def generate_video_thumbnail(video_path):
    """Generate thumbnail from uploaded video"""
    try:
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            return None
        
        fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
        total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        frame_no = min(int(fps * 1), total_frames // 2 if total_frames > 0 else 0)
        cap.set(cv2.CAP_PROP_POS_FRAMES, frame_no)
        
        ret, frame = cap.read()
        cap.release()
        
        if ret:
            timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
            thumbnail_filename = f'video_{timestamp}.jpg'
            thumbnail_path = os.path.join(app.config['THUMBNAIL_FOLDER'], thumbnail_filename)
            cv2.imwrite(thumbnail_path, frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
            return thumbnail_filename
        return None
    except Exception as e:
        print(f"Error generating thumbnail: {e}")
        return None

@app.route('/')
def index():
    categories = Category.query.order_by(Category.name).all()
    videos_by_category = {}
    for category in categories:
        videos_by_category[category.name] = Video.query.filter_by(category_id=category.id).order_by(Video.upload_date.desc()).all()
    return render_template('index.html', categories=categories, videos_by_category=videos_by_category)

@app.route('/calendar')
def calendar():
    videos = Video.query.order_by(Video.upload_date.desc()).all()
    videos_by_date = {}
    for video in videos:
        date_key = video.upload_date.strftime('%Y-%m-%d')
        videos_by_date.setdefault(date_key, []).append(video)
    return render_template('calendar.html', videos_by_date=videos_by_date)

@app.route('/health')
def health():
    """Health check endpoint for Docker"""
    return jsonify({"status": "healthy"}), 200

@app.route('/uploads/<path:filename>')
def uploaded_file(filename):
    return send_from_directory(app.config['UPLOAD_FOLDER'], filename, as_attachment=False)

@app.route('/thumbnails/<path:filename>')
def thumbnail_file(filename):
    return send_from_directory(app.config['THUMBNAIL_FOLDER'], filename, as_attachment=False)

@app.route('/add_category', methods=['POST'])
def add_category():
    category_name = request.form.get('category_name', '').strip()
    if category_name:
        existing = Category.query.filter_by(name=category_name).first()
        if not existing:
            new_category = Category(name=category_name)
            db.session.add(new_category)
            db.session.commit()
    return redirect(url_for('index'))

@app.route('/add_youtube', methods=['POST'])
def add_youtube():
    youtube_url = request.form.get('youtube_url')
    category_id = request.form.get('category_id')
    
    if youtube_url and category_id:
        thumbnail_filename, video_title = extract_youtube_thumbnail(youtube_url)
        if thumbnail_filename or video_title:
            new_video = Video(
                title=video_title or "YouTube Video",
                thumbnail_path=thumbnail_filename or '',
                youtube_url=youtube_url,
                is_youtube=True,
                category_id=int(category_id)
            )
            db.session.add(new_video)
            db.session.commit()
    return redirect(url_for('index'))

@app.route('/upload_video', methods=['POST'])
def upload_video():
    if 'video_file' not in request.files:
        return redirect(url_for('index'))
    
    file = request.files['video_file']
    category_id = request.form.get('category_id')
    video_title = request.form.get('video_title', 'Untitled Video').strip()
    
    if file and allowed_file(file.filename) and category_id:
        filename = secure_filename(file.filename)
        timestamp = datetime.now().strftime('%Y%m%d%H%M%S')
        filename = f"{timestamp}_{filename}"
        save_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(save_path)
        
        thumbnail_filename = generate_video_thumbnail(save_path)
        
        new_video = Video(
            title=video_title or filename,
            thumbnail_path=thumbnail_filename or '',
            video_path=filename,
            is_youtube=False,
            category_id=int(category_id)
        )
        db.session.add(new_video)
        db.session.commit()
    return redirect(url_for('index'))

@app.route('/get_categories')
def get_categories():
    categories = Category.query.order_by(Category.name).all()
    return jsonify([{'id': c.id, 'name': c.name} for c in categories])

@app.route('/delete_video/<int:video_id>', methods=['POST'])
def delete_video(video_id):
    video = Video.query.get_or_404(video_id)
    
    if video.thumbnail_path:
        tpath = os.path.join(app.config['THUMBNAIL_FOLDER'], video.thumbnail_path)
        if os.path.exists(tpath):
            try:
                os.remove(tpath)
            except Exception:
                pass
    
    if not video.is_youtube and video.video_path:
        vpath = os.path.join(app.config['UPLOAD_FOLDER'], video.video_path)
        if os.path.exists(vpath):
            try:
                os.remove(vpath)
            except Exception:
                pass
    
    db.session.delete(video)
    db.session.commit()
    return redirect(request.referrer or url_for('index'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
PYEOF

# Create templates
echo "📝 Creating templates/index.html..."
cat > templates/index.html <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Video Organizer - Gallery</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
  <nav class="navbar">
    <h1>📹 Video Organizer</h1>
    <div class="nav-links">
      <a href="{{ url_for('index') }}" class="active">Gallery</a>
      <a href="{{ url_for('calendar') }}">Calendar</a>
    </div>
  </nav>
  <div class="container">
    <div class="section">
      <h2>➕ Create New Category</h2>
      <form action="{{ url_for('add_category') }}" method="POST" class="form-inline">
        <input type="text" name="category_name" placeholder="Enter category name" required>
        <button type="submit" class="btn btn-primary">Add Category</button>
      </form>
    </div>
    <div class="section">
      <h2>🔗 Add YouTube Link</h2>
      <form action="{{ url_for('add_youtube') }}" method="POST" class="form-inline">
        <input type="url" name="youtube_url" placeholder="Enter YouTube URL" required>
        <select name="category_id" required>
          <option value="">Select Category</option>
          {% for category in categories %}
            <option value="{{ category.id }}">{{ category.name }}</option>
          {% endfor %}
        </select>
        <button type="submit" class="btn btn-primary">Add YouTube Link</button>
      </form>
    </div>
    <div class="section">
      <h2>📤 Upload Video</h2>
      <form action="{{ url_for('upload_video') }}" method="POST" enctype="multipart/form-data" class="form-inline">
        <input type="text" name="video_title" placeholder="Video title" required>
        <input type="file" name="video_file" accept="video/*" required>
        <select name="category_id" required>
          <option value="">Select Category</option>
          {% for category in categories %}
            <option value="{{ category.id }}">{{ category.name }}</option>
          {% endfor %}
        </select>
        <button type="submit" class="btn btn-primary">Upload Video</button>
      </form>
    </div>
    <div class="section">
      <h2>🗂️ Video Gallery by Category</h2>
      {% if videos_by_category %}
        {% for category_name, videos in videos_by_category.items() %}
          {% if videos %}
            <div class="category-section">
              <h3 class="category-title">{{ category_name }}</h3>
              <div class="video-grid">
                {% for video in videos %}
                  <div class="video-card">
                    <div class="thumbnail-container">
                      {% if video.is_youtube %}
                        <a href="{{ video.youtube_url }}" target="_blank">
                          {% if video.thumbnail_path %}
                            <img src="{{ url_for('thumbnail_file', filename=video.thumbnail_path) }}" alt="{{ video.title }}">
                          {% else %}
                            <div class="thumb-fallback">🎬 YouTube</div>
                          {% endif %}
                          <div class="play-overlay">▶️</div>
                        </a>
                      {% else %}
                        <a href="{{ url_for('uploaded_file', filename=video.video_path) }}" target="_blank">
                          {% if video.thumbnail_path %}
                            <img src="{{ url_for('thumbnail_file', filename=video.thumbnail_path) }}" alt="{{ video.title }}">
                          {% else %}
                            <div class="thumb-fallback">🎥 Video</div>
                          {% endif %}
                          <div class="play-overlay">▶️</div>
                        </a>
                      {% endif %}
                    </div>
                    <div class="video-info">
                      <h4>{{ video.title }}</h4>
                      <p class="video-date">{{ video.upload_date.strftime('%Y-%m-%d %H:%M') }}</p>
                      <span class="badge">{{ 'YouTube' if video.is_youtube else 'Uploaded' }}</span>
                      <form action="{{ url_for('delete_video', video_id=video.id) }}" method="POST" style="display:inline;">
                        <button type="submit" class="btn-delete" onclick="return confirm('Delete this video?')">🗑️</button>
                      </form>
                    </div>
                  </div>
                {% endfor %}
              </div>
            </div>
          {% endif %}
        {% endfor %}
      {% else %}
        <p class="empty-state">No videos yet. Add some YouTube links or upload videos!</p>
      {% endif %}
    </div>
  </div>
  <script src="{{ url_for('static', filename='js/script.js') }}"></script>
</body>
</html>
HTMLEOF

echo "📝 Creating templates/calendar.html..."
cat > templates/calendar.html <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Video Organizer - Calendar</title>
  <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
</head>
<body>
  <nav class="navbar">
    <h1>📅 Video Organizer - Calendar View</h1>
    <div class="nav-links">
      <a href="{{ url_for('index') }}">Gallery</a>
      <a href="{{ url_for('calendar') }}" class="active">Calendar</a>
    </div>
  </nav>
  <div class="container">
    <div class="section">
      <h2>📆 Videos by Upload Date</h2>
      {% if videos_by_date %}
        <div class="calendar-view">
          {% for date, videos in videos_by_date.items() %}
            <div class="date-section">
              <h3 class="date-header">{{ date }}</h3>
              <div class="video-grid">
                {% for video in videos %}
                  <div class="video-card">
                    <div class="thumbnail-container">
                      {% if video.is_youtube %}
                        <a href="{{ video.youtube_url }}" target="_blank">
                          {% if video.thumbnail_path %}
                            <img src="{{ url_for('thumbnail_file', filename=video.thumbnail_path) }}" alt="{{ video.title }}">
                          {% else %}
                            <div class="thumb-fallback">🎬 YouTube</div>
                          {% endif %}
                          <div class="play-overlay">▶️</div>
                        </a>
                      {% else %}
                        <a href="{{ url_for('uploaded_file', filename=video.video_path) }}" target="_blank">
                          {% if video.thumbnail_path %}
                            <img src="{{ url_for('thumbnail_file', filename=video.thumbnail_path) }}" alt="{{ video.title }}">
                          {% else %}
                            <div class="thumb-fallback">🎥 Video</div>
                          {% endif %}
                          <div class="play-overlay">▶️</div>
                        </a>
                      {% endif %}
                    </div>
                    <div class="video-info">
                      <h4>{{ video.title }}</h4>
                      <p class="video-category">Category: {{ video.category.name }}</p>
                      <p class="video-time">{{ video.upload_date.strftime('%H:%M') }}</p>
                      <span class="badge">{{ 'YouTube' if video.is_youtube else 'Uploaded' }}</span>
                      <form action="{{ url_for('delete_video', video_id=video.id) }}" method="POST" style="display:inline;">
                        <button type="submit" class="btn-delete" onclick="return confirm('Delete this video?')">🗑️</button>
                      </form>
                    </div>
                  </div>
                {% endfor %}
              </div>
            </div>
          {% endfor %}
        </div>
      {% else %}
        <p class="empty-state">No videos uploaded yet!</p>
      {% endif %}
    </div>
  </div>
  <script src="{{ url_for('static', filename='js/script.js') }}"></script>
</body>
</html>
HTMLEOF

# CSS
echo "📝 Creating static/css/style.css..."
cat > static/css/style.css <<'CSSEOF'
* { box-sizing: border-box; margin:0; padding:0; }
body { font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial; background:#f3f6ff; color:#222; }
.navbar { background:white; padding:1rem 2rem; display:flex; justify-content:space-between; align-items:center; box-shadow:0 2px 8px rgba(0,0,0,0.05); }
.navbar h1 { color:#5b6df6; font-size:1.5rem; }
.nav-links a { margin-left:1rem; text-decoration:none; color:#444; padding:0.5rem 1rem; border-radius:6px; font-weight:500; }
.nav-links a.active, .nav-links a:hover { background:#5b6df6; color:white; }
.container { max-width:1200px; margin:1.5rem auto; padding:1rem; }
.section { background:white; border-radius:10px; padding:1.5rem; margin-bottom:1.5rem; box-shadow:0 6px 20px rgba(0,0,0,0.03); }
.section h2 { color:#5b6df6; margin-bottom:1rem; font-size:1.3rem; }
.form-inline { display:flex; gap:0.7rem; flex-wrap:wrap; align-items:center; }
.form-inline input, .form-inline select { padding:0.6rem; border-radius:8px; border:1px solid #e6e9f0; min-width:180px; font-size:0.95rem; }
.form-inline input:focus, .form-inline select:focus { outline:none; border-color:#5b6df6; }
.btn-primary { background:#5b6df6; color:white; border:none; padding:0.6rem 1.2rem; border-radius:8px; cursor:pointer; font-weight:600; transition:all 0.2s; }
.btn-primary:hover { background:#4a5ce6; transform:translateY(-1px); }
.category-section { margin-bottom:2rem; }
.category-title { color:#764ba2; font-size:1.2rem; margin-bottom:1rem; padding-bottom:0.5rem; border-bottom:2px solid #5b6df6; }
.video-grid { display:grid; grid-template-columns: repeat(auto-fill,minmax(260px,1fr)); gap:1.2rem; margin-top:1rem; }
.video-card { background:#fafbff; border-radius:10px; overflow:hidden; box-shadow:0 6px 18px rgba(16,24,40,0.03); transition:transform 0.2s, box-shadow 0.2s; }
.video-card:hover { transform:translateY(-4px); box-shadow:0 12px 24px rgba(16,24,40,0.08); }
.thumbnail-container { position:relative; padding-top:56.25%; background:#000; overflow:hidden; }
.thumbnail-container img { position:absolute; inset:0; width:100%; height:100%; object-fit:cover; }
.thumb-fallback { position:absolute; inset:0; display:flex; align-items:center; justify-content:center; background:#333; color:white; font-size:1.5rem; }
.play-overlay { position:absolute; left:50%; top:50%; transform:translate(-50%,-50%); font-size:2.8rem; color:white; opacity:0; transition:opacity 0.2s; text-shadow:0 2px 8px rgba(0,0,0,0.5); }
.thumbnail-container:hover .play-overlay { opacity:1; }
.video-info { padding:1rem; }
.video-info h4 { color:#333; margin-bottom:0.4rem; font-size:1rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.video-date, .video-category, .video-time { color:#666; font-size:0.85rem; margin-bottom:0.3rem; }
.badge { background:#5b6df6; color:white; padding:0.25rem 0.7rem; border-radius:999px; font-size:0.8rem; margin-right:0.5rem; }
.btn-delete { background:#ff5b6a; color:white; border:none; padding:0.3rem 0.7rem; border-radius:6px; cursor:pointer; font-size:0.9rem; transition:background 0.2s; }
.btn-delete:hover { background:#ff3d4f; }
.empty-state { padding:3rem; text-align:center; color:#999; font-size:1.1rem; }
.date-header { background:linear-gradient(135deg,#667eea,#764ba2); color:white; padding:0.8rem 1rem; border-radius:8px; margin-bottom:1rem; font-size:1.1rem; }
@media (max-width:760px){ .form-inline { flex-direction:column; } .form-inline input, .form-inline select { width:100%; } .navbar { flex-direction:column; gap:0.8rem; } .nav-links{ display:flex; gap:0.5rem; } }
CSSEOF

# JS
echo "📝 Creating static/js/script.js..."
cat > static/js/script.js <<'JSEOF'
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('form').forEach(form => {
    form.addEventListener('submit', () => {
      const btn = form.querySelector('button[type="submit"]');
      if (btn) { 
        btn.disabled = true; 
        btn.textContent = 'Processing...'; 
      }
    });
  });

  const fileInput = document.querySelector('input[type="file"]');
  if (fileInput) {
    fileInput.addEventListener('change', (e) => {
      const f = e.target.files[0];
      if (!f) return;
      const mb = (f.size / 1024 / 1024).toFixed(2);
      console.log(`Selected: ${f.name} (${mb} MB)`);
      if (mb > 500) {
        alert('File size exceeds 500MB limit!');
        e.target.value = '';
      }
    });
  }
});
JSEOF

# Create .gitignore
echo "📝 Creating .gitignore..."
cat > .gitignore <<'GITEOF'
__pycache__/
*.py[cod]
*.so
.Python
env/
venv/
*.egg-info/
instance/
*.db
*.sqlite
uploads/*
!uploads/.gitkeep
thumbnails/*
!thumbnails/.gitkeep
*.log
.vscode/
.idea/
*.swp
.DS_Store
Thumbs.db
GITEOF

# Add .gitkeep placeholders
touch uploads/.gitkeep
touch thumbnails/.gitkeep

# Create virtual environment
echo "🐍 Creating virtual environment ($VENV_DIR) using $PYTHON_BIN..."
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Error: $PYTHON_BIN not found. Install Python 3 and retry."
  exit 1
fi

"$PYTHON_BIN" -m venv "$VENV_DIR"

# Activate venv and install dependencies
echo "⚙️ Activating venv and installing Python packages..."
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip setuptools wheel $PIP_ARGS
python -m pip install -r requirements.txt $PIP_ARGS

deactivate

echo ""
echo "✅ Setup complete with Docker support!"
echo ""
echo "📂 Project created: $PROJECT_DIR/"
echo ""
echo "🐳 Docker files created:"
echo "   - Dockerfile"
echo "   - docker-compose.yaml"
echo "   - .dockerignore (includes *.md exclusion)"
echo "   - coolify.yaml"
echo ""
echo "🚀 Next steps:"
echo ""
echo "   1. Test locally with Docker:"
echo "      cd $PROJECT_DIR"
echo "      docker-compose up --build"
echo ""
echo "   2. Deploy to Coolify:"
echo "      git init"
echo "      git add ."
echo "      git commit -m 'Initial commit'"
echo "      git remote add origin https://github.com/your-repo.git"
echo "      git push -u origin main"
echo ""
echo "   Then in Coolify:"
echo "      - Create new resource → Public Repository"
echo "      - Enter repo URL"
echo "      - Configure volumes (uploads, thumbnails, instance)"
echo "      - Deploy!"
echo ""
echo "🎉 Happy deploying!"
