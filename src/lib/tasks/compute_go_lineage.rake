desc '####################### Clean'
task compute_go_lineage: :environment do

  puts 'Executing...'

  dev_null = Logger.new("/dev/null")
  Rails.logger = dev_null
  ActiveRecord::Base.logger = dev_null

  data_dir = Pathname.new(APP_CONFIG[:data_dir])
  go_dir = data_dir + 'go'
  FileUtils.mkdir_p(go_dir)

  h_go_db_names = {'biological_process' => 'GO Biological Processes', 'cellular_component' => 'GO Cellular Components', 'molecular_function' => 'GO Molecular Functions'}

  def add_lineage tmp, cur_id, h_go
    if h_go[cur_id] and h_go[cur_id][:is_a].size > 0
      h_go[cur_id][:is_a].each do |k|
  #    puts "add #{k} -> #{tmp.to_json}..."
        tmp.push k if !tmp.include? k
       	tmp = add_lineage(tmp, k, h_go)
      end
    end
    return tmp
  end
  
  #load in memory adjacency tables                                                                                                                                                     
  h_go = {}
  h_replacements = {}
#  h_adj = {}                                                                                                                                                                          
  
  url = "http://purl.obolibrary.org/obo/go.obo"
  `wget -O #{go_dir + 'go.obo'} #{url}`
  version = ''
  cur = {:is_a => [], :lineage => [], :replaced_by => [], :consider => [], :obsolete => false}
  File.open(go_dir + 'go.obo', "r") do |f|
    while (l = f.gets) do
      if m = l.match(/^data-version: releases\/([\-\d]+)/)
        version = m[1]
      elsif m = l.match(/^id\: (GO\:\d+)/)
        cur[:id] = m[1]
      elsif m = l.match(/^namespace\: (.+)/)
        #        cur[:namespace] = m[1]
	cur[:db_name] = h_go_db_names[m[1]]
      elsif  m = l.match(/^name\: (.+)/)
        cur[:name] = m[1]
      elsif  m = l.match(/^is_a\: (GO\:\d+)/)
        cur[:is_a].push m[1]
      elsif m = l.match(/^replaced_by\: (GO\:\d+)/)
        cur[:replaced_by].push m[1]
      elsif m = l.match(/^consider\: (GO\:\d+)/)
        cur[:consider].push m[1]
      elsif l.match?(/^is_obsolete:\s*true/)
        cur[:obsolete] = true
      elsif l.chomp == '[Term]'
        if cur[:id]
          if cur[:obsolete]
            h_replacements[cur[:id]] = {
              name: cur[:name],
              db_name: cur[:db_name],
              replaced_by: cur[:replaced_by],
              consider: cur[:consider]
            }
          elsif cur[:is_a] and cur[:is_a].size > 0
            h_go[cur[:id]] = {
              id: cur[:id],
              name: cur[:name],
              db_name: cur[:db_name],
              is_a: cur[:is_a],
              lineage: []
            }
          end
        end
        cur = {:is_a => [], :lineage => [], :replaced_by => [], :consider => [], :obsolete => false}
      end
    end
  end
  
  puts "#{h_go.keys.size} go terms loaded"
  puts "#{h_replacements.keys.size} obsolete GO terms with replacement metadata"
  puts "adding lineage recursively..."
  h_go.keys.each do |k|
    #  puts k    
    h_go[k][:lineage] = add_lineage([], k, h_go)
    #    puts "Result: " + h_go[k][:linage].to_json
  end
  
  ## write lineage
  puts "write GO..."
  File.open(go_dir + "go.json", 'w') do |f|
    f.write(h_go.to_json)
  end

  puts "write GO replacements..."
  File.open(go_dir + "go_replacements.json", 'w') do |f|
    f.write(h_replacements.to_json)
  end

  output_json = Pathname.new(APP_CONFIG[:data_dir]) + 'tmp' + 'tool_versions.json'
  
  h_tool_versions = Basic.safe_parse_json(output_json, {})
  
  h_tool_versions['go'] = version
  puts h_tool_versions.to_json
  File.open(output_json, 'w') do |f|
    f.write(h_tool_versions.to_json)
  end
  

end
