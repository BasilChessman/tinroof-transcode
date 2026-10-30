USER GUIDE

This application is a player, editor, lossless converter, exporter and downloader for MPEG and modern video files. It is a new application for current macOS, written from scratch; it uses FFmpeg for all media work.

OPENING FILES
• File > Open Files… (⌘O), or drag files onto the player window or the app icon.
• Several MPEG files (VOB, TS, MPG…) selected together are joined into one stream in name order.
• Opening one part of a split recording offers to open all parts: VTS_01_1.VOB + VTS_01_2.VOB (DVD), Recording.ts + .ts.001 (DreamBox), Movie~0.vid + ~1.vid (Humax), .tp0 + .tp1 (Homecast).
• A demuxed .m2v/.m1v/.mpv file automatically opens with the audio file of the same name (.aiff, .wav, .m1a, .mp2, .mpa, .ac3).
• File > Open DVD… (⇧⌘O) opens a disc, a VIDEO_TS folder or any folder of VOB files and asks which title to open. Encrypted DVDs are not supported.
• File > Open URL… (⌘U) plays or downloads http(s)/ftp streams. If yt-dlp is installed (brew install yt-dlp), web page addresses are resolved to their video.

PLAYING
• Space or double-click: play/stop. J / K / L: shuttle backwards / stop / forwards; pressing again doubles the speed. Option-J / Option-L: slow motion. Option-K or Option-▶: loop the selection.
• ← / →: one frame. ↑ / ↓: previous / next keyframe. Option-← / Option-→: go to In / Out.
• Page Up / Page Down (or the ◀◀ ▶▶ buttons): skip (10 s by default, set in Settings); with Option, one minute. Home / End: one minute.
• ⌘↑ / ⌘↓: volume. Option-↑ / Option-↓: sound on / off. Scroll wheel: step through frames.
• Window > Full Screen (⌘0); Esc or 0 leaves full screen. Window > Half / Actual / Double Size.
• Use the Video and Audio pop-ups to choose tracks (PIDs). For surround (AC3/5.1) audio the mode pop-up offers Stereo Mix, Front Mix, Surround (Pro Logic), L/R, Center, LS/RS and LFE.

SELECTING AND EDITING
• Set In and Out with I and O, by Shift-dragging on the timeline, by Shift with the arrow keys, or with Edit > Go to Time… (⌘G): enter a time, “T-” for In, “-T” for Out, or “A-B”. X cancels the selection.
• Edit > Cut / Copy / Paste work on the selection. The clipboard survives closing a file, so you can copy from one stream and paste into another to join them.
• Edit > Trim (⌘T) temporarily restricts the player to the selection; Revert Trimming (⇧⌘T) brings everything back. Trimming never loses edits.
• Undo and Redo have unlimited levels. Revert All Changes restores the original.
• Edit > Delete Audio Track removes the current audio track from Save As and conversions.
• List > Edit List shows each segment of the edited stream; double-click to select it.
• Editing never changes your source files.
• Edits are frame accurate in the player and in all Export commands. Lossless commands (Save As, Convert, Demux) copy video without re-encoding, so each piece starts on a keyframe: by default partial GOPs at a cut are discarded; enable “Preserve GOPs at In/Out” in Settings to keep them instead.

LOSSLESS CONVERSION (File menu)
• Convert to MPEG / MPEG with MP2 Audio — DVD-compatible program stream.
• Convert to TS / TS with MP2 Audio — transport stream.
• Convert to MP4 / MOV / MKV (Lossless Remux) — any codec, re-wrapped.
• Demux to M2V and AIFF / M1A / AC3, Demux to M2V, AIFF, M1A or AC3.
• The MPEG and M2V commands require MPEG-1/2 video. All audio tracks are converted unless “Convert only the selected audio track” is set.
• Save As… (⇧⌘S) copies the edited stream to the same or another container.
• Fix Timecode Breaks (Edit menu) scans the stream, lists breaks in the Log and regenerates timestamps on conversion. “Fix streams with data breaks” in Settings makes every conversion tolerant of corrupt data.

EXPORTING (File menu)
• Export to QuickTime (⌘E), MPEG-4 (⇧⌘E), AVI, MKV / WebM, DV, MPEG-2 (DVD), Export Audio (⌥⌘E) and Export Frame (⌥⌘F).
• Video codecs: H.264 and HEVC (x264/x265 or Apple hardware), Apple ProRes (Proxy–4444, software or hardware), Avid DNxHR (LB–444), GoPro CineForm, Hap / Hap Alpha / Hap Q, QuickTime Animation, PNG, uncompressed 10-bit (v210), AV1, VP9, FFV1, Ut Video, Motion JPEG, DV/DVCPRO50, MPEG-4 Part 2 (DivX/Xvid compatible), MPEG-2. Codecs not present in the installed ffmpeg are marked and cannot be chosen.
• NotchLC, Hap, ProRes RAW and other professional formats can be opened and converted from whenever ffmpeg can decode them.
• Picture: frame size (or Unscaled), frame rate with optional frame blending, field dominance, interlaced scaling, better downscaling, motion-adaptive deinterlacing, rotation and flip, zoom with X/Y stretch and centre offset, cropping relative to Destination, Source or Scale.
• Sound: format, channels, sample rate, bit rate, surround downmix; Pass Through copies the original audio.
• Adjustments: brightness, contrast, saturation, volume, automatic volume, and a watermark text drawn in the lower-right corner.
• Preview renders the current frame with all settings. Presets save and load complete settings.

BATCH PROCESSING
• List > Batch List (⌘B). While it is open, Save As, Convert, Demux, Export and Download commands are added to it instead of running (this can be turned off in Settings).
• Add Files… (or drop files onto the list) applies one task to many files, with options to fix timecode breaks, join the files, or reuse the previous folder and settings.
• Go starts, Stop finishes the running tasks and stops; Hold skips a task, Repeat runs it again, Redirect changes the destination folder. Set the number of simultaneous tasks, automatic start, and a script (AppleScript, shell script or app) to run when everything has finished.

OTHER WINDOWS
• Stream Info (⌘I): container, size, duration, keyframes, and every track with its PID, codec, frame size, aspect, frame rate, scan type, sample rate and channels.
• Log (⇧⌘L): conversions, errors and stream checks. Check Stream decodes the whole stream and reports damage.
• Progress (⌥⌘P): conversions running outside the batch list.

REQUIREMENTS
macOS 14 or later and ffmpeg (brew install ffmpeg). Hap export needs an ffmpeg built with libsnappy (scripts/build_ffmpeg.sh). Optional: yt-dlp for web pages.
