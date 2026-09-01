require_relative 'test_helper'
require 'httparty'

# Hits the real providers. That is the point: these cams are resolved by scraping
# pages and calling undocumented endpoints, so the failure this suite exists to
# catch is a provider changing something on their end. A failure here means either
# the provider drifted or this particular cam went offline -- check the cam in a
# browser before assuming the code is broken.
class LiveProviderTest < ResolverTest
  SURFCHEX_CAM = 'hatteras-web-cam'.freeze
  SURFLINE_CAM = '58349ab8e411dc743a5d52a0'.freeze
  IPCAMLIVE_CAM = 'broadwaycam'.freeze

  def test_surfchex_resolves_a_signed_playlist_url
    get "/camera/surfchex/#{SURFCHEX_CAM}"
    assert_equal 200, last_response.status
    # The slug has to become the hls cam id, and the URL has to carry a pass.
    assert_includes last_response.body, '/hls/hatteras1/index.m3u8'
    assert_includes last_response.body, 'st='
  end

  def test_surfchex_streams_a_playable_playlist
    assert_streams_playable_playlist 'surfchex', SURFCHEX_CAM
  end

  # An unsigned surfchex playlist returns 200 with a short promo loop rather than
  # an error, so a broken resolver looks like a working one. The filler is a finite
  # VOD and a live window never ends, which is what actually separates them.
  def test_surfchex_serves_the_live_stream_and_not_the_promo_loop
    get "/stream/surfchex/#{SURFCHEX_CAM}"
    assert_equal 200, last_response.status
    refute_includes last_response.body, '#EXT-X-PLAYLIST-TYPE:VOD'
    refute_includes last_response.body, '#EXT-X-ENDLIST'
    refute_includes last_response.body, 'promo' # what they name the filler today
  end

  def test_surfline_resolves_a_playlist_url
    get "/camera/surfline/#{SURFLINE_CAM}"
    assert_equal 200, last_response.status
    assert_match %r{\Ahttps?://.+\.m3u8\z}, last_response.body
  end

  def test_surfline_streams_a_playable_playlist
    assert_streams_playable_playlist 'surfline', SURFLINE_CAM
  end

  def test_ipcamlive_resolves_a_stream_url
    get "/camera/ipcamlive/#{IPCAMLIVE_CAM}"
    assert_equal 200, last_response.status
    assert_match %r{\Ahttps?://.+\.m3u8\z}, last_response.body
  end

  # ipcamlive needs no headers and no token, so it still gets a plain redirect --
  # meaning the player fetches the playlist, not us. Follow it here anyway, so this
  # provider is held to the same "a player could actually play this" bar as the
  # other two rather than just to the shape of its URL.
  def test_ipcamlive_redirects_to_a_playable_playlist
    get "/stream/ipcamlive/#{IPCAMLIVE_CAM}"
    assert_equal 302, last_response.status
    location = last_response.headers['Location']
    playlist = HTTParty.get(location)
    assert_equal 200, playlist.code
    assert_playable_segments rewrite_playlist(playlist.body.to_s, location)
  end

  def test_unknown_cams_are_not_found
    { 'surfchex' => 'not-a-real-cam',
      'surfline' => '000000000000000000000000',
      'ipcamlive' => 'not-a-real-cam' }.each do |provider, camera|
      get "/camera/#{provider}/#{camera}"
      assert_equal 404, last_response.status, "/camera/#{provider} should 404 an unknown cam"
    end
    # /stream resolves identically and just halts earlier, so one provider covers it.
    get '/stream/surfchex/not-a-real-cam'
    assert_equal 404, last_response.status, '/stream should 404 an unknown cam'
  end

  def test_unknown_providers_are_not_found
    get '/camera/notaprovider/whatever'
    assert_equal 404, last_response.status
  end

  private

  def assert_streams_playable_playlist(provider, camera)
    get "/stream/#{provider}/#{camera}"
    assert_equal 200, last_response.status
    assert_equal 'application/vnd.apple.mpegurl', last_response.content_type
    assert_playable_segments last_response.body
  end

  # Segments must be absolute, or the player can't fetch them without us. Check the
  # newest one and never the oldest: the front of a live window can roll off the CDN
  # between our playlist fetch and the segment fetch. HEAD, because segments run to
  # megabytes and only the status is being asserted.
  def assert_playable_segments(playlist)
    assert_match %r{\A#EXTM3U}, playlist
    urls = playlist.each_line.map(&:strip).reject { |line| line.empty? || line.start_with?('#') }
    refute_empty urls, 'playlist listed no segments'
    urls.each { |url| assert_match %r{\Ahttps?://}, url, "segment is not an absolute URL: #{url}" }
    assert_equal 200, HTTParty.head(urls.last).code, "live-edge segment did not fetch: #{urls.last}"
  end
end
