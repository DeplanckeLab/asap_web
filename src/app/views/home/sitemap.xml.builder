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

  # Public project show pages (same visibility as anonymous users: public, not deleted, not sandbox).
  Project.where(public: true, being_deleted: false, sandbox: false).find_each do |project|
    xml.url do
      xml.loc "#{base}#{project_path(project)}"
      xml.changefreq 'weekly'
      xml.priority '0.5'
      xml.lastmod project.updated_at.iso8601 if project.updated_at
    end
  end
end
