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

# Configuration - Fixed database path
INSTANCE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'instance')
os.makedirs(INSTANCE_PATH, exist_ok=True)

app.config['SQLALCHEMY_DATABASE_URI'] = os.environ.get(
    'DATABASE_URL', 
    f'sqlite:///{os.path.join(INSTANCE_PATH, "database.db")}'
)
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['UPLOAD_FOLDER'] = os.environ.get('UPLOAD_FOLDER', 'uploads')
app.config['THUMBNAIL_FOLDER'] = os.environ.get('THUMBNAIL_FOLDER', 'thumbnails')
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024  # 500MB
app.config['ALLOWED_EXTENSIONS'] = {'mp4', 'avi', 'mov', 'mkv', 'webm', 'flv'}

db = SQLAlchemy(app)

# Ensure directories exist
os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)
os.makedirs(app.config['THUMBNAIL_FOLDER'], exist_ok=True)

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
