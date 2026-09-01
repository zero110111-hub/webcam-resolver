require_relative 'test_helper'

# No network. Covers the playlist rewriting that both surfline and surfchex rely
# on to hand a player URLs it can fetch for itself.
class PlaylistTest < ResolverTest
  BASE = 'https://cdn.example.com/cam/hi/index.m3u8'.freeze

  MASTER = <<~PLAYLIST
    #EXTM3U
    #EXT-X-STREAM-INF:BANDWIDTH=800000
    low/stream.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2500000

    high/stream.m3u8
  PLAYLIST

  MEDIA = <<~PLAYLIST
    #EXTM3U
    #EXT-X-TARGETDURATION:5
    #EXT-X-MEDIA-SEQUENCE:120
    #EXT-X-MAP:URI="init.mp4?e=1&st=token"
    #EXTINF:5.00000,
    seg120.mp4?e=1&st=token

    #EXTINF:5.00000,
    seg121.mp4?e=1&st=token
  PLAYLIST

  def test_best_variant_picks_the_highest_bandwidth_rendition
    assert_equal 'high/stream.m3u8', best_variant(MASTER)
  end

  def test_best_variant_prefers_bandwidth_over_position
    reversed = MASTER.sub('BANDWIDTH=800000', 'BANDWIDTH=9000000')
    assert_equal 'low/stream.m3u8', best_variant(reversed)
  end

  def test_best_variant_returns_nil_for_a_media_playlist
    assert_nil best_variant(MEDIA)
  end

  def test_segments_become_absolute_urls
    rewritten = rewrite_playlist(MEDIA, BASE)
    assert_includes rewritten, 'https://cdn.example.com/cam/hi/seg120.mp4?e=1&st=token'
  end

  # Players fetch #EXT-X-MAP before any segment, so a relative one left behind
  # would break playback before the first frame.
  def test_map_uri_becomes_an_absolute_url
    rewritten = rewrite_playlist(MEDIA, BASE)
    assert_includes rewritten, '#EXT-X-MAP:URI="https://cdn.example.com/cam/hi/init.mp4?e=1&st=token"'
  end

  def test_tags_and_blank_lines_survive_the_rewrite
    rewritten = rewrite_playlist(MEDIA, BASE)
    assert_includes rewritten, '#EXT-X-MEDIA-SEQUENCE:120'
    assert_equal MEDIA.lines.count, rewritten.lines.count
  end

  def test_absolute_segment_urls_are_left_alone
    playlist = "#EXTM3U\n#EXTINF:5.0,\nhttps://other.example.com/seg.ts\n"
    assert_includes rewrite_playlist(playlist, BASE), 'https://other.example.com/seg.ts'
  end

  def test_root_relative_segments_resolve_against_the_host
    playlist = "#EXTM3U\n#EXTINF:5.0,\n/elsewhere/seg.ts\n"
    assert_includes rewrite_playlist(playlist, BASE), 'https://cdn.example.com/elsewhere/seg.ts'
  end
end
