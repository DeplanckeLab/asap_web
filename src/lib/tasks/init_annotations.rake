# frozen_string_literal: true

# Backfill / repair Clas from list_cat_json (legacy task, aligned with Basic.add_clas rules).
#
# ASAP auto Clas are created only when the category label maps to an ontology term.
#
# Env:
#   PROJECT_ID=id          only this project (numeric id)
#   PROJECT_KEY=key        only this project (projects.key)
#   MAX_PROJECTS=n         cap projects loaded (testing)
#   DRY_RUN=1              no writes; log would_create / would_update / no_change and annot payload
#   COMPARE_EXISTING=0     disable misaligned ASAP scan
#   COMPARE_EXISTING=1     run misaligned ASAP scan on every project in the relation
#
# Misaligned scan (unexpected / misaligned_asap_cla lines) runs when PROJECT_KEY or PROJECT_ID is set,
# unless COMPARE_EXISTING=0. With COMPARE_EXISTING=1 it also runs for bulk project runs.

module InitAnnotationsRake
  module_function

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.strip.downcase)
  end

  def normalize_cot_id_field(value)
    s = value.to_s.strip
    return nil if s.empty?

    s.split(",").map(&:strip).reject(&:empty?).first
  end

  def attrs_differ?(cla, intended)
    return true if cla.cell_set_id != intended[:cell_set_id]

    if normalize_cot_id_field(cla.cell_ontology_term_ids) != normalize_cot_id_field(intended[:cell_ontology_term_ids])
      return true
    end

    cla.name.to_s != intended[:name].to_s ||
      cla.cat.to_s != intended[:cat].to_s ||
      cla.user_id != intended[:user_id] ||
      cla.num != intended[:num] ||
      cla.ontology_term_type_id != intended[:ontology_term_type_id]
  end

  # Intended ASAP row for this slot, or nil if this rake would not create an ASAP cla here
  # (blank/numeric label, or no perfect ontology term match).
  def asap_intended_attrs(p, a, i, k, list_cats, cot_by_label, h_cell_sets, asap_src)
    raw_label = k.to_s.strip
    return nil if raw_label.blank? || raw_label.match(/^-?[0-9.]+$/)

    cot = cot_by_label[raw_label]
    return nil unless cot

    {
      cla_source_id: asap_src,
      name: "",
      annot_id: a.id,
      num: 1,
      cat_idx: i,
      cell_set_id: h_cell_sets[[a.id, i]],
      cell_ontology_term_ids: cot.id,
      ontology_term_type_id: Basic.ontology_term_type_id_for_cot_ids(cot.id),
      cat: k,
      user_id: a.user_id,
      project_id: p.id
    }
  end

  def build_cot_map_for_annot(a, list_cats, names_map, organism_tax_id = nil)
    labels_for_cot = []
    list_cats.each do |k|
      s = k.to_s.strip
      labels_for_cot << s if s != "" && !s.match(/^-?[0-9.]+$/)
      alias_label = names_map[k]
      if alias_label.present?
        s2 = alias_label.to_s.strip
        labels_for_cot << s2 if s2 != "" && !s2.match(/^-?[0-9.]+$/)
      end
    end
    Basic.h_cell_ontology_terms_by_cat_label(labels_for_cot.uniq, organism_tax_id)
  end

  # ASAP clas on this project that the rake would never (re)assert for a managed slot.
  def report_misaligned_and_extra_asap(p, asap_src, dry_run:)
    h_cell_sets = {}
    p.annot_cell_sets.find_each do |acs|
      h_cell_sets[[acs.annot_id, acs.cat_idx]] = acs.cell_set_id
    end

    puts "--- compare_existing: project #{p.id} (#{p.key}) ASAP cla_source_id=#{asap_src} dry_run=#{dry_run} ---"

    Cla.where(project_id: p.id, cla_source_id: asap_src).find_each do |cla|
      a = cla.annot
      unless a && a.dim == 1 && a.list_cat_json.present?
        puts "unexpected_asap_cla cla_id=#{cla.id} reason=no_discrete_annot annot_id=#{cla.annot_id} cat_idx=#{cla.cat_idx}"
        next
      end

      list_cats = Basic.safe_parse_json(a.list_cat_json, [])
      unless list_cats.is_a?(Array)
        puts "unexpected_asap_cla cla_id=#{cla.id} reason=bad_list_cat_json annot_id=#{a.id}"
        next
      end

      if cla.cat_idx.nil? || cla.cat_idx.negative? || cla.cat_idx >= list_cats.size
        puts "unexpected_asap_cla cla_id=#{cla.id} reason=cat_idx_out_of_range annot_id=#{a.id} cat_idx=#{cla.cat_idx.inspect} list_size=#{list_cats.size}"
        next
      end

      k = list_cats[cla.cat_idx]
      h_cat_aliases = Basic.safe_parse_json(a.cat_aliases_json, {})
      h_cat_aliases = {} unless h_cat_aliases.is_a?(Hash)
      names_map = h_cat_aliases["names"]
      names_map = {} unless names_map.is_a?(Hash)
      cot_by_label = build_cot_map_for_annot(a, list_cats, names_map, p.organism&.tax_id)

      intended = asap_intended_attrs(p, a, cla.cat_idx, k, list_cats, cot_by_label, h_cell_sets, asap_src)
      if intended.nil?
        reason = if k.to_s.strip.blank? || k.to_s.strip.match(/^-?[0-9.]+$/)
                   'rake_skips_slot_numeric_or_blank'
                 else
                   'rake_skips_slot_no_ontology_match'
                 end
        puts "unexpected_asap_cla cla_id=#{cla.id} reason=#{reason} annot_id=#{a.id} cat_idx=#{cla.cat_idx} cat=#{cla.cat.inspect}"
        next
      end

      if cla.cat.to_s != list_cats[cla.cat_idx].to_s
        puts "misaligned_asap_cla cla_id=#{cla.id} reason=cla.cat_ne_list_cat annot_id=#{a.id} cat_idx=#{cla.cat_idx} cla.cat=#{cla.cat.inspect} list=#{list_cats[cla.cat_idx].inspect}"
      elsif attrs_differ?(cla, intended)
        puts "misaligned_asap_cla cla_id=#{cla.id} reason=attrs_differ_from_intended annot_id=#{a.id} cat_idx=#{cla.cat_idx} " \
             "stored cell_set_id=#{cla.cell_set_id} intended=#{intended[:cell_set_id]} " \
             "stored cot_ids=#{cla.cell_ontology_term_ids.inspect} intended=#{intended[:cell_ontology_term_ids].inspect} " \
             "stored name=#{cla.name.inspect} intended=#{intended[:name].inspect} " \
             "stored ott_id=#{cla.ontology_term_type_id.inspect} intended=#{intended[:ontology_term_type_id].inspect}"
      end
    end
  end
end

desc "Init annotations: create or update Clas from discrete cell metadata (ASAP auto + optional alias rows)"
task init_annotations: :environment do
  puts "init_annotations starting"

  dry_run = InitAnnotationsRake.truthy?(ENV["DRY_RUN"])
  puts "DRY_RUN=#{dry_run}"

  h_users = {}
  User.find_each { |u| h_users[u.id] = u }

  project_relation = Project.order(:id)
  if ENV["PROJECT_KEY"].present?
    key = ENV["PROJECT_KEY"].to_s.strip
    project_relation = project_relation.where(key: key)
    raise "init_annotations: no project with PROJECT_KEY=#{key.inspect}" unless project_relation.exists?
  end
  project_relation = project_relation.where(id: ENV["PROJECT_ID"].to_i) if ENV["PROJECT_ID"].present?

  max_projects = ENV["MAX_PROJECTS"].to_i

  scoped_one_project = ENV["PROJECT_KEY"].present? || ENV["PROJECT_ID"].present?
  compare_existing =
    if ENV["COMPARE_EXISTING"].to_s.strip == "0"
      false
    elsif InitAnnotationsRake.truthy?(ENV["COMPARE_EXISTING"])
      true
    else
      scoped_one_project
    end

  asap_src = Basic::ASAP_AUTO_CLA_SOURCE_ID
  manual_src = 1

  process_project = lambda do |p|
    if compare_existing
      InitAnnotationsRake.report_misaligned_and_extra_asap(p, asap_src, dry_run: dry_run)
    end

    h_cell_sets = {}
    p.annot_cell_sets.find_each do |annot_cell_set|
      h_cell_sets[[annot_cell_set.annot_id, annot_cell_set.cat_idx]] = annot_cell_set.cell_set_id
    end

    p.annots.where(dim: 1).where.not(list_cat_json: [nil, ""]).find_each do |a|
      puts "#{a.id}: #{a.name} => #{a.list_cat_json}"
      list_cats = Basic.safe_parse_json(a.list_cat_json, [])
      next unless list_cats.is_a?(Array)

      h_cat_aliases = Basic.safe_parse_json(a.cat_aliases_json, {})
      h_cat_aliases = {} unless h_cat_aliases.is_a?(Hash)
      names_map = h_cat_aliases["names"]
      names_map = {} unless names_map.is_a?(Hash)

      puts h_cat_aliases.to_json

      cot_by_label = InitAnnotationsRake.build_cot_map_for_annot(a, list_cats, names_map, p.organism&.tax_id)

      sel_clas = []
      h_nber_clas = {}

      list_cats.each_index do |i|
        k = list_cats[i]
        cell_set_id = h_cell_sets[[a.id, i]]

        sel_cla = ""
        num = 0
        raw_label = k.to_s.strip

        if raw_label != "" && !raw_label.match(/^-?[0-9.]+$/)
          cot = cot_by_label[raw_label]
          if cot
            num = 1
            h_cla = {
              cla_source_id: asap_src,
              name: "",
              annot_id: a.id,
              num: num,
              cat_idx: i,
              cell_set_id: cell_set_id,
              cell_ontology_term_ids: cot.id,
              ontology_term_type_id: Basic.ontology_term_type_id_for_cot_ids(cot.id),
              cat: k,
              user_id: a.user_id,
              project_id: p.id
            }

            cla = Cla.find_by(annot_id: a.id, cat_idx: i, cla_source_id: asap_src)
            if dry_run
              if cla.nil?
                puts "dry_run would_create asap annot_id=#{a.id} cat_idx=#{i} attrs=#{h_cla.inspect}"
              elsif InitAnnotationsRake.attrs_differ?(cla, h_cla)
                puts "dry_run would_update asap cla_id=#{cla.id} annot_id=#{a.id} cat_idx=#{i} attrs=#{h_cla.inspect}"
              else
                puts "dry_run no_change asap cla_id=#{cla.id} annot_id=#{a.id} cat_idx=#{i}"
              end
              sel_cla = cla ? cla.id : ""
            else
              if cla
                cla.assign_attributes(h_cla)
                cla.save if cla.changed?
              else
                cla = Cla.create!(h_cla)
              end
              sel_cla = cla.id
            end
          end
        end

        alias_annot_name = names_map[k].presence&.to_s&.strip
        if alias_annot_name.present? && alias_annot_name != raw_label && !alias_annot_name.match(/^-?[0-9.]+$/)
          num += 1
          puts alias_annot_name
          cot = cot_by_label[alias_annot_name]
          puts(cot&.to_json || "null")
          cot_ids = cot&.id
          user_id = if h_cat_aliases["user_ids"] && h_cat_aliases["user_ids"][k]
                      h_cat_aliases["user_ids"][k].to_i
                    else
                      a.user_id
                    end

          h_cla = {
            cla_source_id: manual_src,
            name: cot ? "" : alias_annot_name,
            annot_id: a.id,
            num: num,
            cat_idx: i,
            cell_set_id: cell_set_id,
            cell_ontology_term_ids: cot_ids,
            ontology_term_type_id: (cot ? Basic.ontology_term_type_id_for_cot_ids(cot.id) : nil),
            cat: k,
            user_id: (names_map[k].present? ? user_id : 1),
            project_id: p.id
          }

          cla = Cla.find_by(annot_id: a.id, cat_idx: i, cla_source_id: manual_src)

          if dry_run
            if cla.nil?
              puts "dry_run would_create manual annot_id=#{a.id} cat_idx=#{i} attrs=#{h_cla.inspect}"
              puts "dry_run would_create_cla_vote manual (after cla exists) annot_id=#{a.id} cat_idx=#{i} user_id=#{user_id}"
            elsif InitAnnotationsRake.attrs_differ?(cla, h_cla)
              puts "dry_run would_update manual cla_id=#{cla.id} annot_id=#{a.id} cat_idx=#{i} attrs=#{h_cla.inspect}"
            else
              puts "dry_run no_change manual cla_id=#{cla.id} annot_id=#{a.id} cat_idx=#{i}"
            end
            if cla
              h_cla_vote = {
                cla_source_id: manual_src,
                cla_id: cla.id,
                user_name: (user_id == 1) ? "admin" : (h_users[user_id]&.displayed_name || "user_#{user_id}"),
                user_id: user_id,
                comment: "",
                agree: true
              }
              if ClaVote.find_by(h_cla_vote)
                puts "dry_run vote_exists manual cla_id=#{cla.id}"
              else
                puts "dry_run would_create_cla_vote manual cla_id=#{cla.id} attrs=#{h_cla_vote.inspect}"
              end
              sel_cla = cla.id
            end
          else
            if cla
              cla.assign_attributes(h_cla)
              cla.save if cla.changed?
            else
              cla = Cla.create!(h_cla)
            end
            sel_cla = cla.id

            h_cla_vote = {
              cla_source_id: manual_src,
              cla_id: cla.id,
              user_name: (user_id == 1) ? "admin" : (h_users[user_id]&.displayed_name || "user_#{user_id}"),
              user_id: user_id,
              comment: "",
              agree: true
            }
            cla_vote = ClaVote.find_by(h_cla_vote)
            ClaVote.create!(h_cla_vote) unless cla_vote

            cla.update({ nber_agree: 1 })
          end
        end

        sel_clas.push sel_cla
        h_nber_clas[i] = Cla.where(
          annot_id: a.id,
          num: 1,
          cat_idx: i,
          project_id: p.id
        ).count
      end

      h_cla_sum = {
        nber_clas: (0..list_cats.size - 1).to_a.map { |idx| (sel_clas[idx] == "") ? 0 : h_nber_clas[idx] },
        selected_cla_ids: sel_clas
      }

      if dry_run
        puts "dry_run would_update_annot cat_info_json annot_id=#{a.id} payload=#{h_cla_sum.inspect}"
      else
        a.update({ cat_info_json: h_cla_sum.to_json })
      end
    end
  end

  if max_projects.positive?
    project_relation.limit(max_projects).each(&process_project)
  else
    project_relation.find_each(batch_size: 50, &process_project)
  end

  puts "init_annotations finished"
end
