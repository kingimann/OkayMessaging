// Selects the real player on mobile (dart:io) and a stub on web, where the
// decrypted bytes have no file to play from.
export 'listing_video_stub.dart'
    if (dart.library.io) 'listing_video_native.dart';
