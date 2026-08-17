# frozen_string_literal: true

require_relative 'test_base_without_fixtures'

class SearchEngineCrawlerTest < TestBaseWithoutFixtures
  test 'matches Googlebot variants' do
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Googlebot/2.1; +http://www.google.com/bot.html) Chrome/139.0.0.0 Safari/537.36')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.7258.154 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; Google-InspectionTool/1.0;)')
  end

  test 'matches Bingbot variants' do
    assert SearchEngineCrawler.match?('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm) Chrome/116.0.1938.76 Safari/537.36')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; BingPreview/1.0b)')
    assert SearchEngineCrawler.match?('msnbot/2.0b (+http://search.msn.com/msnbot.htm)')
  end

  test 'matches other search engines that index the public site' do
    assert SearchEngineCrawler.match?('DuckDuckBot/1.1; (+http://duckduckgo.com/duckduckbot.html)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; Yahoo! Slurp; http://help.yahoo.com/help/us/ysearch/slurp)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; YandexBot/3.0; +http://yandex.com/bots)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; Baiduspider/2.0; +http://www.baidu.com/search/spider.html)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 (Applebot/0.1; +http://www.apple.com/go/applebot)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; SeznamBot/3.2; +http://napoveda.seznam.cz/en/seznambot-intro/)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 (compatible; MojeekBot/0.11; +https://www.mojeek.com/bot.html)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; Amazonbot/0.1; +https://developer.amazon.com/support/amazonbot)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot)')
    assert SearchEngineCrawler.match?('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; PerplexityBot/1.0; +https://perplexity.ai/perplexitybot)')
  end

  test 'does not match browsers, uptime monitors, or scrape-only SEO tools' do
    assert_not SearchEngineCrawler.match?(nil)
    assert_not SearchEngineCrawler.match?('')
    assert_not SearchEngineCrawler.match?('Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:153.0) Gecko/20100101 Firefox/153.0')
    assert_not SearchEngineCrawler.match?('Blackbox-Exporter/0.28.0')
    assert_not SearchEngineCrawler.match?('Mozilla/5.0+(compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)')
    assert_not SearchEngineCrawler.match?('curl/8.0.1')
    assert_not SearchEngineCrawler.match?('Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)')
    assert_not SearchEngineCrawler.match?('Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)')
    assert_not SearchEngineCrawler.match?('Mozilla/5.0 (compatible; Bytespider; https://bytedance.sg.larkoffice.com/docx)')
  end
end
