const express = require('express');
const app = express();
const port = 3000;

app.set('view engine', 'ejs');
app.use(express.static('public'));  // For static files like JS/CSS

// Teacher page: Instructions to stream via RTMP
app.get('/teacher', (req, res) => {
    const streamKey = 'mystream';  // Generate dynamically or use auth
    res.render('teacher', { streamUrl: `rtmp://your-server-ip/live/${streamKey}` });
});

// Viewer page: Embed HLS player
app.get('/viewer', (req, res) => {
    const streamKey = 'mystream';
    res.render('viewer', { hlsUrl: `http://your-server-ip/hls/${streamKey}.m3u8` });
});

app.listen(port, () => {
    console.log(`App listening at http://localhost:${port}`);
});