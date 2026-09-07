require 'sinatra'
require 'json'
require 'uri'
require 'httparty'
use Rack::Logger

SURFCHEX_SITE = 'https://www.surfchex.com'.freeze
SURFLINE_REFERER = { 'Referer' => 'https://www.surfline.com/' }.freeze
# Providers whose playlist we serve ourselves instead of redirecting to it, and the
# headers each one's CDN wants when we fetch it.
PLAYLIST_HEADERS = { 'surfline' => SURFLINE_REFERER, 'surfchex' => {} }.freeze

# Cam ids never change, so remember the slug -> id lookup. Stream passes expire,
# so keep one until it's nearly up.
SURFCHEX_CAM_IDS = {}
SURFCHEX_PASSES = {}

helpers do
  def logger
    request.logger
  end
end

# Surfchex cam pages ship a CAM_PAGES map of hls cam id => page path, which is how
# a page slug like "hatteras-web-cam" becomes the "hatteras1" the hls path wants.
def surfchex_cam_id(camera)
  return SURFCHEX_CAM_IDS[camera] if SURFCHEX_CAM_IDS[camera]

  markup = HTTParty.get("#{SURFCHEX_SITE}/cams/#{camera}/").body.to_s
  pages = JSON.parse(markup[/CAM_PAGES\s*=\s*(\{.*?\})/m, 1].to_s) rescue nil
  cam_id = pages&.key("/cams/#{camera}/")
  # Unknown slugs still render a page, so fall back to treating the param as a cam
  # id -- but don't cache that guess, or a bad page fetch pins it for good.
  return camera unless cam_id
  SURFCHEX_CAM_IDS[camera] = cam_id
end

# Surfchex serves a promo loop instead of the live stream unless the playlist is
# signed with a short-lived pass, so fetch one the same way their player does.
def surfchex_stream_pass(cam_id)
  pass = SURFCHEX_PASSES[cam_id]
  return pass if pass && pass['e'].to_i - Time.now.to_i > 60

  response = HTTParty.get('https://surfchex.com/api/stream-pass', query: { cam: cam_id })
  return nil unless response.success?
  pass = response.parsed_response
  return nil unless pass.is_a?(Hash) && pass['st']
  SURFCHEX_PASSES[cam_id] = pass
end

def get_camera_url(provider, camera)
  case provider
  when 'surfchex'
    cam_id = surfchex_cam_id(camera)
    pass = surfchex_stream_pass(cam_id)
    return nil unless pass
    "#{SURFCHEX_SITE}/hls/#{cam_id}/index.m3u8?#{URI.encode_www_form(st: pass['st'], e: pass['e'])}"
  when 'ipcamlive'
    response = HTTParty.get("https://www.ipcamlive.com/ajax/getcamerastreamstate.php?cameraalias=#{camera}").body
    return nil if response.nil? || response.empty?
    stream_data = JSON.parse(response) rescue nil
    return nil unless stream_data&.dig('details', 'streamid')
    logger.info "Stream data: #{stream_data}"
    "#{stream_data['details']['address']}streams/#{stream_data['details']['streamid']}/stream.m3u8"
  when 'surfline'
    # Surfline Referer-gates the embed page (and the playlist), so send one.
    markup = HTTParty.get("https://embed.cdn-surfline.com/cam/#{camera}.html", headers: SURFLINE_REFERER).body
    markup.scan(/(https:\/\/hls\.cdn-surfline\.com\/[^"']+?\.m3u8)/).flatten.first
  end
end

def absolutize(uri, base)
  URI.join(base, uri).to_s
rescue URI::Error
  uri
end

# Take the top rendition of a master playlist rather than whatever is listed first.
# Returns nil for a media playlist, which has no renditions to choose between.
def best_variant(playlist)
  lines = playlist.each_line.map(&:strip)
  top = lines.each_index.select { |i| lines[i].start_with?('#EXT-X-STREAM-INF') }
             .max_by { |i| lines[i][/BANDWIDTH=(\d+)/, 1].to_i }
  top && lines[(top + 1)..-1].find { |l| !l.empty? && !l.start_with?('#') }
end

# Rewrite a media playlist's relative names -- segments, and the `URI="..."` of
# tags like #EXT-X-MAP -- to absolute URLs against the playlist's own address.
def rewrite_playlist(playlist, base)
  playlist.each_line.map do |line|
    stripped = line.strip
    if stripped.empty?
      line
    elsif stripped.start_with?('#')
      line.sub(/URI="([^"]+)"/) { "URI=\"#{absolutize($1, base)}\"" }
    else
      "#{absolutize(stripped, base)}\n"
    end
  end.join
end

# Hand the client a media playlist whose segment URLs are absolute, so it pulls
# video straight from the provider's CDN with no proxying on our side.
def resolve_playlist(url, headers = {})
  playlist = HTTParty.get(url, headers: headers).body.to_s

  # A master playlist only lists renditions, so follow it to the real one. HLS
  # nests exactly one level deep, so this never needs to repeat.
  variant = best_variant(playlist)
  if variant
    url = absolutize(variant, url)
    playlist = HTTParty.get(url, headers: headers).body.to_s
  end

  # An offline cam answers with an error document, not a playlist. Don't hand that
  # to a player dressed up as m3u8.
  return nil unless playlist.start_with?('#EXTM3U')

  rewrite_playlist(playlist, url)
end

get '/' do
  'Get a camera stream URL by visiting /camera/:provider/:camera. For example, /camera/ipcamlive/1234567890.\n\n' +
  'Stream from the camera by visiting /stream/:provider/:camera. For example, /stream/ipcamlive/1234567890.'
end

get '/camera/:provider/:camera' do
  url = get_camera_url(params['provider'], params['camera'])
  if url
    url
  else
    status 404
    'Camera not found'
  end
end

get '/stream/:provider/:camera' do
  url = get_camera_url(params['provider'], params['camera'])
  halt 404, 'Camera not found' unless url

  cdn_headers = PLAYLIST_HEADERS[params['provider']]
  redirect url unless cdn_headers

  # Surfline gates the .m3u8 playlist behind a Referer header the client can't
  # send, and surfchex signs its playlists with a pass that expires in minutes.
  # Either way we serve the playlist ourselves: the player re-requests this URL
  # for every refresh of the live window, so it always gets a working one.
  playlist = resolve_playlist(url, cdn_headers)
  halt 404, 'Camera not found' unless playlist
  content_type 'application/vnd.apple.mpegurl'
  playlist
end

get '/stream/:provider/:camera.m3u8' do
  url = get_camera_url(params['provider'], params['camera'])
  halt 404, 'Camera not found' unless url

  cdn_headers = PLAYLIST_HEADERS[params['provider']]
  redirect url unless cdn_headers

  playlist = resolve_playlist(url, cdn_headers)
  halt 404, 'Camera not found' unless playlist
  content_type 'application/vnd.apple.mpegurl'
  playlist
end
