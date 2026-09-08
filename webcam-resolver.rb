require 'sinatra'
require 'json'
require 'uri'
require 'httparty'
require 'date'

use Rack::Logger

SURFCHEX_SITE = 'https://www.surfchex.com'.freeze
SURFLINE_REFERER = { 'Referer' => 'https://www.surfline.com/' }.freeze

PLAYLIST_HEADERS = {
  'surfline' => SURFLINE_REFERER,
  'surfchex' => {}
}.freeze

SURFCHEX_CAM_IDS = {}
SURFCHEX_PASSES = {}

WILMINGTON_LAT = 34.2104
WILMINGTON_LON = -77.8868

SMART_CAMERAS = {
  'wb1' => { title: 'Wrightsville Beach 1', slug: 'wb3' },
  'bridge' => { title: 'Wrightsville Beach 2', slug: 'bt' },
  'icw' => { title: 'Wrightsville Beach 3', slug: 'bwg' },
  'seapath' => { title: 'Wrightsville Beach 4', slug: 'seapath' },
  'cb1' => { title: 'Carolina Beach 1', slug: 'cb' },
  'cb2' => { title: 'Carolina Beach 2', slug: 'cb2' },
  'kb_beach' => { title: 'Kure Beach 1', slug: 'kb' },
  'kb_street' => {
    title: 'Kure Beach 2',
    slug: 'kure-beach-street-web-cam'
  },
  'downtown' => { title: 'Downtown Wilmington', slug: 'dw' }
}.freeze

SMART_GROUPS = {
  'sunrise' => %w[
    cb1
    cb2
    kb_beach
  ],

  'day' => %w[
    wb1
    bridge
    icw
    seapath
    cb1
    cb2
    kb_beach
    kb_street
    downtown
  ],

  'sunset' => %w[
    downtown
    kb_street
    icw
  ],

  'night' => %w[
    downtown
    kb_street
    bridge
  ]
}.freeze

helpers do
  def logger
    request.logger
  end
end

def surfchex_cam_id(camera)
  return SURFCHEX_CAM_IDS[camera] if SURFCHEX_CAM_IDS[camera]

  markup = HTTParty.get("#{SURFCHEX_SITE}/cams/#{camera}/").body.to_s

  pages = JSON.parse(
    markup[/CAM_PAGES\s*=\s*(\{.*?\})/m, 1].to_s
  ) rescue nil

  cam_id = pages&.key("/cams/#{camera}/")

  return camera unless cam_id

  SURFCHEX_CAM_IDS[camera] = cam_id
end

def surfchex_stream_pass(cam_id)
  pass = SURFCHEX_PASSES[cam_id]

  if pass && pass['e'].to_i - Time.now.to_i > 60
    return pass
  end

  response = HTTParty.get(
    'https://surfchex.com/api/stream-pass',
    query: { cam: cam_id }
  )

  return nil unless response.success?

  pass = response.parsed_response

  return nil unless pass.is_a?(Hash)
  return nil unless pass['st']

  SURFCHEX_PASSES[cam_id] = pass
end

def get_camera_url(provider, camera)
  case provider

  when 'surfchex'
    cam_id = surfchex_cam_id(camera)
    pass = surfchex_stream_pass(cam_id)

    return nil unless pass

    query = URI.encode_www_form(
      st: pass['st'],
      e: pass['e']
    )

    "#{SURFCHEX_SITE}/hls/#{cam_id}/index.m3u8?#{query}"

  when 'ipcamlive'
    response = HTTParty.get(
      "https://www.ipcamlive.com/ajax/getcamerastreamstate.php?cameraalias=#{camera}"
    ).body

    return nil if response.nil? || response.empty?

    stream_data = JSON.parse(response) rescue nil

    return nil unless stream_data
    return nil unless stream_data.dig('details', 'streamid')

    logger.info "Stream data: #{stream_data}"

    address = stream_data['details']['address']
    stream_id = stream_data['details']['streamid']

    "#{address}streams/#{stream_id}/stream.m3u8"

  when 'surfline'
    markup = HTTParty.get(
      "https://embed.cdn-surfline.com/cam/#{camera}.html",
      headers: SURFLINE_REFERER
    ).body

    markup.scan(
      /(https:\/\/hls\.cdn-surfline\.com\/[^"']+?\.m3u8)/
    ).flatten.first
  end
end

def absolutize(uri, base)
  URI.join(base, uri).to_s
rescue URI::Error
  uri
end

def best_variant(playlist)
  lines = playlist.each_line.map(&:strip)

  indexes = lines.each_index.select do |i|
    lines[i].start_with?('#EXT-X-STREAM-INF')
  end

  top = indexes.max_by do |i|
    lines[i][/BANDWIDTH=(\d+)/, 1].to_i
  end

  return nil unless top

  lines[(top + 1)..-1].find do |line|
    !line.empty? && !line.start_with?('#')
  end
end

def rewrite_playlist(playlist, base)
  playlist.each_line.map do |line|
    stripped = line.strip

    if stripped.empty?
      line

    elsif stripped.start_with?('#')
      line.sub(/URI="([^"]+)"/) do
        "URI=\"#{absolutize($1, base)}\""
      end

    else
      "#{absolutize(stripped, base)}\n"
    end
  end.join
end

def resolve_playlist(url, headers = {})
  playlist = HTTParty.get(
    url,
    headers: headers
  ).body.to_s

  variant = best_variant(playlist)

  if variant
    url = absolutize(variant, url)

    playlist = HTTParty.get(
      url,
      headers: headers
    ).body.to_s
  end

  return nil unless playlist.start_with?('#EXTM3U')

  rewrite_playlist(playlist, url)
end

def normalize_degrees(value)
  value % 360.0
end

def degrees_to_radians(value)
  value * Math::PI / 180.0
end

def radians_to_degrees(value)
  value * 180.0 / Math::PI
end

def solar_event_utc(date, latitude, longitude, sunrise:)
  day = date.yday
  lng_hour = longitude / 15.0

  approximate_time =
    if sunrise
      day + ((6.0 - lng_hour) / 24.0)
    else
      day + ((18.0 - lng_hour) / 24.0)
    end

  mean_anomaly =
    (0.9856 * approximate_time) - 3.289

  true_longitude =
    mean_anomaly +
    (1.916 * Math.sin(degrees_to_radians(mean_anomaly))) +
    (0.020 * Math.sin(degrees_to_radians(2 * mean_anomaly))) +
    282.634

  true_longitude = normalize_degrees(true_longitude)

  right_ascension =
    radians_to_degrees(
      Math.atan(
        0.91764 *
        Math.tan(
          degrees_to_radians(true_longitude)
        )
      )
    )

  right_ascension = normalize_degrees(right_ascension)

  longitude_quadrant =
    (true_longitude / 90.0).floor * 90.0

  ra_quadrant =
    (right_ascension / 90.0).floor * 90.0

  right_ascension += longitude_quadrant - ra_quadrant
  right_ascension /= 15.0

  sin_declination =
    0.39782 *
    Math.sin(
      degrees_to_radians(true_longitude)
    )

  cos_declination =
    Math.cos(
      Math.asin(sin_declination)
    )

  cos_hour_angle =
    (
      Math.cos(degrees_to_radians(90.833)) -
      (
        sin_declination *
        Math.sin(degrees_to_radians(latitude))
      )
    ) /
    (
      cos_declination *
      Math.cos(degrees_to_radians(latitude))
    )

  hour_angle =
    if sunrise
      360.0 -
      radians_to_degrees(
        Math.acos(cos_hour_angle)
      )
    else
      radians_to_degrees(
        Math.acos(cos_hour_angle)
      )
    end

  hour_angle /= 15.0

  local_mean_time =
    hour_angle +
    right_ascension -
    (0.06571 * approximate_time) -
    6.622

  utc_hour =
    normalize_degrees(
      (local_mean_time - lng_hour) * 15.0
    ) / 15.0

  Time.utc(
    date.year,
    date.month,
    date.day
  ) + (utc_hour * 3600)
end

def smart_camera_mode(now = Time.now.utc)
  date = now.to_date

  sunrise = solar_event_utc(
    date,
    WILMINGTON_LAT,
    WILMINGTON_LON,
    sunrise: true
  )

  sunset = solar_event_utc(
    date,
    WILMINGTON_LAT,
    WILMINGTON_LON,
    sunrise: false
  )

  sunrise_start = sunrise - (30 * 60)
  sunrise_end   = sunrise + (60 * 60)

  sunset_start = sunset - (60 * 60)
  sunset_end   = sunset + (30 * 60)

  if now >= sunrise_start && now < sunrise_end
    'sunrise'
  elsif now >= sunrise_end && now < sunset_start
    'day'
  elsif now >= sunset_start && now < sunset_end
    'sunset'
  else
    'night'
  end
end

def smart_camera_json(camera_keys)
  camera_keys.map do |key|
    camera = SMART_CAMERAS[key]

    url =
      "https://webcam-resolver.onrender.com" \
      "/stream/surfchex/" \
      "#{camera[:slug]}.m3u8"

    {
      location: 'North Carolina',
      title: camera[:title],
      url_1080p: url,
      url_1080p_hdr: url,
      url_4k: url,
      url_4k_hdr: url
    }
  end
end

get '/' do
  'Webcam resolver is running.'
end

get '/smart.json' do
  mode = smart_camera_mode

  cameras =
    smart_camera_json(
      SMART_GROUPS[mode]
    )

  content_type :json

  headers(
    'Cache-Control' => 'no-store, no-cache, must-revalidate, max-age=0',
    'Pragma' => 'no-cache',
    'Expires' => '0',
    'X-Smart-Camera-Mode' => mode
  )

  JSON.pretty_generate(cameras)
end

get '/camera/:provider/:camera' do
  camera = params['camera'].sub(/\.m3u8\z/, '')

  url = get_camera_url(
    params['provider'],
    camera
  )

  if url
    url
  else
    status 404
    'Camera not found'
  end
end

get '/stream/:provider/:camera' do
  camera = params['camera'].sub(/\.m3u8\z/, '')

  url = get_camera_url(
    params['provider'],
    camera
  )

  halt 404, 'Camera not found' unless url

  cdn_headers = PLAYLIST_HEADERS[
    params['provider']
  ]

  redirect url unless cdn_headers

  playlist = resolve_playlist(
    url,
    cdn_headers
  )

  halt 404, 'Camera not found' unless playlist

  content_type 'application/vnd.apple.mpegurl'

  playlist
end
