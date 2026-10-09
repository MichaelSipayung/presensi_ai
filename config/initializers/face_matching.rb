module FaceMatching
  TAU = ENV.fetch("FACE_TAU", "0.60").to_f   # satu nilai untuk presensi dan dedup
  K   = ENV.fetch("ATTENDANCE_K", "200").to_i
end