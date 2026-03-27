base = ENV.fetch('SERVER_URL').chomp('/')

entries = [
  [root_path, 'weekly', '1.0'],
  [projects_path, 'weekly', '0.9'],
  *info_menu_links.map { |link| [link[:path], 'monthly', '0.6'] }
]

xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
xml.urlset xmlns: 'http://www.sitemaps.org/schemas/sitemap/0.9' do
  entries.each do |path, changefreq, priority|
    xml.url do
      xml.loc "#{base}#{path}"
      xml.changefreq changefreq
      xml.priority priority
    end
  end
end
