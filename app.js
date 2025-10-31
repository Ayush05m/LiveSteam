const express = require('express');
const path = require('path');
const NodeMediaServer = require('node-media-server');

const app = express();
const PORT = 3000;

// ===== 1. NODE MEDIA SERVER (RTMP → HLS) =====
const config = {
  rtmp: {
    port: 1935,
    chunk_size: 60000,
    gop_cache: true,
    ping: 30,
    ping_timeout: 60
  },
  http: {
    port: 8000,
    allow_origin: '*',
    mediaroot: './media'
  },
  trans: {
    ffmpeg: '/usr/bin/ffmpeg',
    tasks: [
      {
        app: 'live',
        hls: true,
        hlsFlags: '[hls_time=1:hls_list_size=3:hls_flags=delete_segments+omit_endlist]'
      }
    ]
  }
};

const nms = new NodeMediaServer(config);
nms.run();

console.log('RTMP ingest → rtmp://35.244.31.40/live/mystream');
console.log('HLS output → http://35.244.31.40:8000/live/mystream.m3u8');

// ===== 2. EXPRESS WEB UI =====
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(express.static('public'));

const STREAM_KEY = 'mystream';

// Teacher page
app.get('/teacher', (req, res) => {
  const rtmpUrl = `rtmp://35.244.31.40/live/${STREAM_KEY}`;
  res.render('teacher', { rtmpUrl });
});

// Viewer page
app.get('/viewer', (req, res) => {
  const hlsUrl = `http://35.244.31.40:8000/live/${STREAM_KEY}.m3u8`;
  res.render('viewer', { hlsUrl });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`Web UI → http://35.244.31.40:${PORT}`);
});