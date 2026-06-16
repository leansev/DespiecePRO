# despiece_pro/main.rb
# Logica principal del plugin Despiece PRO

require 'json'

module BiraEstudio
  module DespiecePro
    PLUGIN_DIR = File.expand_path(File.dirname(__FILE__)).freeze

    module DimHelpers
      module_function

      def ordered_lwt_mm(values_in_inches)
        dims_mm = values_in_inches.map { |value| (value * 25.4).round }
        dims_mm.sort! { |a, b| b <=> a }

        {
          length: dims_mm[0],
          width: dims_mm[1],
          thickness: dims_mm[2]
        }
      end

      def piece_dimensions_mm(entity)
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          raise ArgumentError, 'La entidad debe ser un componente o grupo'
        end

        b = entity.definition.bounds
        raise ArgumentError, 'La pieza no tiene geometria valida' if b.empty?

        t = entity.transformation
        vx = (b.corner(1) - b.corner(0)).transform(t)
        vy = (b.corner(2) - b.corner(0)).transform(t)
        vz = (b.corner(4) - b.corner(0)).transform(t)

        ordered_lwt_mm([vx.length, vy.length, vz.length])
      end
    end

    class Store
      @modules = []
      @scanned_uids = []
      @scanned_entities = []
      SCAN_MATERIAL_NAME = 'DespiecePRO_escaneado'.freeze
      DEFAULT_BADGE_COLOR = '#ff941f'.freeze
      ATTRIBUTE_DICT = 'despiece_pro'.freeze
      ATTRIBUTE_KEY = 'data'.freeze
      MODULE_UID_KEY = 'uid'.freeze

      class << self
        attr_reader :modules, :scanned_entities

        def add_module(name, pieces, uid)
          @modules << {
            name: name,
            uid: uid.to_s,
            pieces: pieces,
            piece_names: {},
            badge_color: DEFAULT_BADGE_COLOR
          }
        end

        def find_module_by_uid(uid)
          uid = uid.to_s
          @modules.find { |entry| entry[:uid].to_s == uid }
        end

        def update_module_name(uid, name)
          entry = find_module_by_uid(uid)
          return unless entry

          name = name.to_s.strip
          name = 'Grupo sin nombre' if name.empty?
          entry[:name] = name
        end

        def update_piece_name(uid, dim_key, name)
          entry = find_module_by_uid(uid)
          return unless entry

          entry[:piece_names] ||= {}
          name = name.to_s.strip
          if name.empty?
            entry[:piece_names].delete(dim_key.to_s)
          else
            entry[:piece_names][dim_key.to_s] = name
          end
        end

        def update_module_badge_color(uid, color)
          entry = find_module_by_uid(uid)
          return unless entry

          color = color.to_s.strip
          color = DEFAULT_BADGE_COLOR unless color =~ /\A#[0-9A-Fa-f]{6}\z/
          entry[:badge_color] = color
        end

        def module_badge_color(entry)
          entry[:badge_color] || DEFAULT_BADGE_COLOR
        end

        def module_piece_count(entry)
          count = 0
          entry[:pieces].each do |piece|
            count += piece[:count]
          end
          count
        end

        def render_module_block(entry)
          uid = entry[:uid]
          acronym = module_acronym(entry[:name])
          color = escape_html(module_badge_color(entry))
          name = escape_html(entry[:name])
          piece_total = module_piece_count(entry)

          piece_rows = entry[:pieces].map do |piece|
            dim_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness])
            piece_name = (entry[:piece_names] || {})[dim_key] || ''
            render_piece_row(
              piece[:count],
              piece[:length],
              piece[:width],
              piece[:thickness],
              acronym,
              piece_name,
              dim_key,
              color
            )
          end.join('')

          '<div class="module" data-entity-id="' + escape_html(uid.to_s) + '">' +
            '<div class="module-header">' +
            '<div class="module-header-left">' +
            '<div class="module-code" style="color:' + color + ';">' + escape_html(acronym) + '</div>' +
            '<div class="module-separator">-</div>' +
            '<div class="module-name">' + name + '</div>' +
            '</div>' +
            '<button class="edit-btn">✎</button>' +
            '</div>' +
            piece_rows +
            '<div class="module-pieces-row">' +
            '<button class="delete-btn">🗑</button>' +
            '<div class="module-pieces">Piezas: ' + piece_total.to_s + '</div>' +
            '</div>' +
            '</div>'
        end

        def render_piece_row(count, length, width, thickness, acronym, piece_name, dim_key, color)
          dims = length.to_s + ' × ' + width.to_s + ' × ' + thickness.to_s + 'mm'

          '<div class="piece-row" data-dim-key="' + escape_html(dim_key) + '">' +
            '<div class="qty">' + count.to_s + 'x</div>' +
            '<div class="dimensions">' + dims + '</div>' +
            '<div><span class="badge" style="color:' + color + ';">' + escape_html(acronym) + '</span></div>' +
            '<div class="piece-name">' + escape_html(piece_name) + '</div>' +
            '</div>'
        end

        def piece_dim_key(length, width, thickness)
          "#{length},#{width},#{thickness}"
        end

        def module_acronym(name)
          name = name.to_s.strip
          return '' if name.empty? || name == 'Grupo sin nombre'

          words = name.split(/\s+/).reject { |word| word.empty? }
          return '' if words.empty?

          if words.length == 1
            words[0][0, 3].upcase
          else
            words.map { |word| word[0].upcase }.join[0, 3]
          end
        end

        def scanned?(uid)
          @scanned_uids.include?(uid.to_s)
        end

        def mark_scanned(entity, uid)
          uid = uid.to_s
          return if uid.empty?
          return if @scanned_uids.include?(uid)

          @scanned_uids << uid
          @scanned_entities << entity
        end

        def remove_module(uid)
          uid = uid.to_s
          entry = find_module_by_uid(uid)
          return unless entry

          @modules.delete(entry)
          @scanned_uids.delete(uid)
          @scanned_entities.delete_if do |entity|
            !entity.valid? || entity_uid(entity) == uid
          end

          model = Sketchup.active_model
          view = model.active_view if model
          view.invalidate if view
        end

        def clear!
          model = Sketchup.active_model
          cleanup_scan_materials(model) if model
          reset_state!

          view = model.active_view if model
          view.invalidate if view
        end

        def reset_state!
          @modules.clear
          @scanned_uids.clear
          @scanned_entities.clear
        end

        def entity_uid(entity)
          return '' unless entity

          uid = entity.get_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY)
          uid.to_s.strip
        rescue StandardError
          ''
        end

        def assign_module_uid(entity)
          uid = entity_uid(entity)
          return uid unless uid.empty?

          uid = generate_module_uid
          entity.set_attribute(ATTRIBUTE_DICT, MODULE_UID_KEY, uid)
          uid
        end

        def generate_module_uid
          "mod_#{Time.now.to_i}_#{rand(10000)}"
        end

        def build_uid_entity_map(model)
          map = {}
          collect_uid_entities(model.entities, map)
          map
        end

        def collect_uid_entities(entities, map)
          entities.each do |entity|
            next unless entity.valid?
            next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)

            uid = entity_uid(entity)
            map[uid] = entity unless uid.empty?

            if entity.is_a?(Sketchup::Group)
              collect_uid_entities(entity.entities, map)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              collect_uid_entities(entity.definition.entities, map)
            end
          end
        end

        def save_to_model(model)
          return false unless model

          model.set_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY, serialize_state)
          Sketchup.status_text = 'Despiece guardado en el modelo'
          true
        rescue StandardError => e
          Sketchup.status_text = "Error al guardar despiece: #{e.message}"
          false
        end

        def restore_from_model(model)
          return 0 unless model

          raw = model.get_attribute(ATTRIBUTE_DICT, ATTRIBUTE_KEY)
          if raw.nil? || raw.to_s.strip.empty?
            puts 'Despiece PRO: sin datos guardados en despiece_pro/data'
            return 0
          end

          data = parse_saved_state(raw)
          reset_state!

          modules_data = data['modules']
          unless modules_data.is_a?(Array)
            puts 'Despiece PRO: JSON guardado sin lista de modulos valida'
            return 0
          end

          uid_map = build_uid_entity_map(model)
          restored_count = 0
          modules_data.each do |entry|
            entry = normalize_hash(entry)
            uid = entry['uid'].to_s.strip
            if uid.empty?
              puts 'Despiece PRO: modulo descartado (sin uid)'
              next
            end

            pieces = deserialize_pieces(entry['pieces'])
            if pieces.empty?
              puts "Despiece PRO: modulo #{uid} descartado (sin piezas validas)"
              next
            end

            entity = uid_map[uid]
            if entity && entity.valid?
              @scanned_uids << uid unless @scanned_uids.include?(uid)
              @scanned_entities << entity unless @scanned_entities.include?(entity)
            else
              puts "Despiece PRO: uid #{uid} no encontrado en el modelo, restaurando datos igual"
            end

            @modules << {
              name: entry['name'].to_s,
              uid: uid,
              pieces: pieces,
              piece_names: normalize_hash(entry['piece_names'] || {}),
              badge_color: entry['badge_color'] || DEFAULT_BADGE_COLOR
            }
            restored_count += 1
          end

          puts "Despiece PRO: #{restored_count} modulos restaurados de #{modules_data.length}"
          restored_count
        rescue JSON::ParserError => e
          puts "Despiece PRO: error al parsear JSON guardado - #{e.message}"
          reset_state!
          0
        rescue StandardError => e
          puts "Despiece PRO: error al restaurar - #{e.class}: #{e.message}"
          reset_state!
          0
        end

        def parse_saved_state(raw)
          return raw if raw.is_a?(Hash)

          JSON.parse(raw.to_s)
        end

        def normalize_hash(value)
          return {} unless value.is_a?(Hash)

          normalized = {}
          value.each do |key, item|
            normalized[key.to_s] = item
          end
          normalized
        end

        def serialize_state
          modules_data = @modules.map do |entry|
            {
              'uid' => entry[:uid].to_s,
              'name' => entry[:name],
              'pieces' => entry[:pieces].map do |piece|
                {
                  'count' => piece[:count],
                  'length' => piece[:length],
                  'width' => piece[:width],
                  'thickness' => piece[:thickness]
                }
              end,
              'piece_names' => entry[:piece_names] || {},
              'badge_color' => module_badge_color(entry)
            }
          end

          JSON.generate('modules' => modules_data)
        end

        def deserialize_pieces(pieces_data)
          return [] unless pieces_data.is_a?(Array)

          pieces_data.map do |piece|
            piece = normalize_hash(piece)
            {
              count: piece['count'].to_i,
              length: piece['length'].to_i,
              width: piece['width'].to_i,
              thickness: piece['thickness'].to_i
            }
          end
        end

        def cleanup_scan_materials(model)
          cleanup_entities(model.entities)
          mat = model.materials[SCAN_MATERIAL_NAME]
          model.materials.remove(mat) if mat
        end

        def cleanup_entities(entities)
          entities.each do |entity|
            if entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
              mat = entity.material
              entity.material = nil if mat && mat.name == SCAN_MATERIAL_NAME
            end

            if entity.is_a?(Sketchup::Group)
              cleanup_entities(entity.entities)
            elsif entity.is_a?(Sketchup::ComponentInstance)
              cleanup_entities(entity.definition.entities)
            end
          end
        end

        def total_pieces
          count = 0
          @modules.each do |entry|
            entry[:pieces].each do |piece|
              count += piece[:count]
            end
          end
          count
        end

        def format_text
          return "Lista vacia.\nEscanea un modulo para comenzar." if @modules.empty?

          lines = []
          @modules.each do |entry|
            lines << "Modulo: #{entry[:name]}"
            lines << '-------------------------'
            entry[:pieces].each do |piece|
              lines << format(
                '%dx  %d x %d x %dmm',
                piece[:count],
                piece[:length],
                piece[:width],
                piece[:thickness]
              )
            end
            lines << '-------------------------'
          end
          lines << "TOTAL: #{total_pieces} piezas"
          lines.join("\n")
        end

        def format_html
          return empty_html if @modules.empty?

          @modules.map { |entry| render_module_block(entry) }.join('')
        end

        def empty_html
          '<div class="empty">Lista vacia. Escanea un modulo para comenzar.</div>'
        end

        def export_payload
          rows = []

          @modules.each do |entry|
            acronym = module_acronym(entry[:name])
            label = if acronym.empty?
                      "\u2014 #{entry[:name]} \u2014"
                    else
                      "\u2014 #{acronym} \u2014 #{entry[:name]}"
                    end

            rows << {
              'type' => 'module',
              'label' => label
            }

            entry[:pieces].each do |piece|
              dim_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness])
              piece_name = (entry[:piece_names] || {})[dim_key].to_s.strip
              piece_name = export_piece_label(acronym, piece_name)

              rows << {
                'type' => 'piece',
                'espesor' => piece[:thickness],
                'cantidad' => piece[:count],
                'largo' => piece[:length],
                'ancho' => piece[:width],
                'nombre' => piece_name,
                'rota' => 1,
                'canto_arr' => 0,
                'canto_aba' => 0,
                'canto_izq' => 0,
                'canto_der' => 0
              }
            end
          end

          {
            'project_title' => project_export_title,
            'rows' => rows
          }
        end

        def project_export_title
          "PROYECTO: #{project_name_for_export} \u2014 #{Time.now.strftime('%d/%m/%Y')}"
        end

        def export_piece_label(acronym, piece_name)
          label = piece_name.to_s.strip
          label = 'Pieza' if label.empty?
          acronym = acronym.to_s.strip
          return label if acronym.empty?

          "#{acronym} - #{label}"
        end

        def project_name_for_export
          model = Sketchup.active_model
          return 'Sin nombre' unless model

          title = model.title.to_s.strip
          return title unless title.empty?

          path = model.path.to_s.strip
          return 'Sin nombre' if path.empty?

          File.basename(path, '.*')
        end

        def escape_html(text)
          text.to_s
              .gsub('&', '&amp;')
              .gsub('<', '&lt;')
              .gsub('>', '&gt;')
              .gsub('"', '&quot;')
        end
      end
    end

    class ExcelExporter
      @last_error = nil

      class << self
        attr_reader :last_error

        def export
          if Store.modules.empty?
            UI.messagebox('No hay modulos para exportar.')
            return
          end

          path = UI.savepanel('Guardar Excel', '', 'despiece.xlsx')
          return unless path

          path = normalize_xlsx_path(path)

          if write_xlsx(path)
            Sketchup.status_text = "Excel exportado: #{path}"
          else
            detail = last_error.to_s.strip
            detail = 'Error desconocido.' if detail.empty?
            UI.messagebox("No se pudo exportar el Excel.\n\n#{detail}")
          end
        end

        def normalize_xlsx_path(path)
          path = path.to_s
          return path if path.downcase.end_with?('.xlsx')

          path + '.xlsx'
        end

        def write_xlsx(xlsx_path)
          @last_error = nil
          python = find_python_executable
          unless python
            @last_error = 'Python no encontrado en pythoncore-*.'
            return false
          end

          script = File.join(PLUGIN_DIR, 'export_excel.py')
          unless File.exist?(script)
            @last_error = "No se encontro el script: #{script}"
            return false
          end

          json_path = File.join(Dir.tmpdir, "despiece_pro_export_#{Time.now.to_i}_#{rand(1000)}.json")
          json_content = JSON.generate(Store.export_payload)
          File.open(json_path, 'wb') do |handle|
            handle.write(json_content)
          end

          command_parts = [python, script, xlsx_path, json_path]
          command_display = command_parts.map { |part| "\"#{part}\"" }.join(' ')
          system(*command_parts)

          if File.exist?(xlsx_path) && File.size?(xlsx_path).to_i > 0
            File.delete(json_path) if File.exist?(json_path)
            true
          else
            @last_error = "Comando ejecutado:\n#{command_display}\n\nJSON enviado:\n#{json_content}"
            false
          end
        rescue StandardError => e
          @last_error = "#{e.class}: #{e.message}"
          false
        end

        def find_python_executable
          candidates = []
          candidates << Dir.glob('C:/Users/Lean/AppData/Local/Python/pythoncore-*/python.exe').first

          local_app = ENV['LOCALAPPDATA'].to_s
          unless local_app.empty?
            candidates << Dir.glob(File.join(local_app, 'Python', 'pythoncore-*', 'python.exe')).first
          end

          candidates.compact.uniq.each do |path|
            next if path.downcase.include?('windowsapps')
            return path if File.exist?(path)
          end

          nil
        end
      end
    end

    class ListDialog
      DIALOG_KEY = 'despiece_pro_list'.freeze

      class << self
        def toggle
          if @dialog && @dialog.visible?
            @dialog.close
          else
            show
          end
        end

        def refresh
          return unless @dialog && @dialog.visible?

          @dialog.set_html(dialog_body_html)
        end

        def show
          restored = Store.restore_from_model(Sketchup.active_model)
          @dialog ||= build_dialog
          @dialog.set_html(dialog_body_html)
          @dialog.show
          Sketchup.status_text = "Despiece PRO: #{restored} modulos restaurados" if restored > 0
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'Despiece PRO - Lista de piezas',
            preferences_key: DIALOG_KEY,
            scrollable: true,
            resizable: true,
            width: 460,
            height: 520,
            style: UI::HtmlDialog::STYLE_DIALOG
          )

          dialog.add_action_callback('clear_list') do |_context|
            Store.clear!
            refresh
          end

          dialog.add_action_callback('update_module_name') do |_context, entity_id, name|
            Store.update_module_name(entity_id, name)
          end

          dialog.add_action_callback('update_piece_name') do |_context, entity_id, dim_key, name|
            Store.update_piece_name(entity_id, dim_key, name)
          end

          dialog.add_action_callback('update_module_badge_color') do |_context, entity_id, color|
            Store.update_module_badge_color(entity_id, color)
          end

          dialog.add_action_callback('refresh_list') do |_context|
            refresh
          end

          dialog.add_action_callback('remove_module') do |_context, entity_id|
            Store.remove_module(entity_id)
            refresh
          end

          dialog.add_action_callback('export_excel') do |_context|
            ExcelExporter.export
          end

          dialog.add_action_callback('save_state') do |_context|
            Store.save_to_model(Sketchup.active_model)
          end

          dialog.set_on_closed do
            @dialog = nil
          end

          dialog
        end

        def dialog_body_html
          html = File.read(File.join(PLUGIN_DIR, 'dialog.html'))
          html.gsub('%CONTENT%', Store.format_html)
              .gsub('%TOTAL%', Store.total_pieces.to_s)
        end
      end
    end

    class ScanModuleTool
      HIGHLIGHT_COLOR = Sketchup::Color.new(0, 220, 100)
      BOX_EDGES = [
        [0, 1], [1, 3], [3, 2], [2, 0],
        [4, 5], [5, 7], [7, 6], [6, 4],
        [0, 4], [1, 5], [2, 6], [3, 7]
      ].freeze

      def activate
        Sketchup.status_text = 'Click en un grupo/modulo que contenga piezas MDF'
        view = Sketchup.active_model.active_view
        view.invalidate if view
      end

      def deactivate(_view)
        Sketchup.status_text = ''
      end

      def draw(view)
        view.line_width = 3
        view.drawing_color = HIGHLIGHT_COLOR

        Store.scanned_entities.each do |entity|
          next unless entity.valid?

          bounds = entity.bounds
          next if bounds.empty?

          corners = (0..7).map { |i| bounds.corner(i) }
          BOX_EDGES.each do |a, b|
            view.draw(GL_LINES, corners[a], corners[b])
          end
        end
      end

      def onCancel(_reason, _view)
        Sketchup.active_model.select_tool(nil)
      end

      def onLButtonDown(_flags, x, y, view)
        model = Sketchup.active_model
        result = model.raytest(view.pickray(x, y))

        unless result
          UI.messagebox('No se encontro ningun grupo o componente')
          return
        end

        _hit_point, path = result
        entity = find_module_entity(path)

        unless entity
          UI.messagebox('Selecciona un grupo o componente (modulo MDF)')
          return
        end

        existing_uid = Store.entity_uid(entity)
        if !existing_uid.empty? && Store.scanned?(existing_uid)
          Sketchup.status_text = 'Este modulo ya fue escaneado'
          return
        end

        pieces = collect_pieces(entity)
        if pieces.empty?
          UI.messagebox('El grupo seleccionado no contiene subgrupos MDF')
          return
        end

        grouped = group_pieces_by_dimensions(pieces)
        if grouped.empty?
          UI.messagebox('No se pudieron obtener dimensiones validas de las piezas')
          return
        end

        module_name = entity.name.to_s.strip
        module_name = 'Grupo sin nombre' if module_name.empty?

        module_uid = Store.assign_module_uid(entity)
        Store.mark_scanned(entity, module_uid)
        Store.add_module(module_name, grouped, module_uid)
        ListDialog.refresh
        view.invalidate

        total = 0
        grouped.each { |piece| total += piece[:count] }
        Sketchup.status_text = "Modulo escaneado: #{module_name} - #{total} piezas agregadas a la lista"
      end

      def find_module_entity(path)
        candidates = path.select do |item|
          item.is_a?(Sketchup::Group) || item.is_a?(Sketchup::ComponentInstance)
        end

        candidates.find { |item| module_container?(item) } || candidates.last
      end

      def module_container?(entity)
        child_container(entity).any? do |child|
          child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
      end

      def collect_pieces(entity)
        unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          return []
        end

        pieces = []
        direct_children = direct_mdf_children(child_container(entity))

        direct_children.each do |child|
          pieces << child if piece_entity?(child)
        end

        containers = direct_children.select { |child| container_entity?(child) }
        sort_containers_for_scan(containers).each do |child|
          pieces.concat(collect_pieces(child))
        end

        pieces
      end

      def child_container(entity)
        entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      end

      def direct_mdf_children(container)
        children = []
        container.each do |child|
          next unless child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)

          children << child
        end
        children
      end

      def entity_children(entity)
        child_container(entity)
      end

      def piece_entity?(entity)
        entity_has_faces?(entity)
      end

      def container_entity?(entity)
        !entity_has_faces?(entity) && entity_has_subgroups?(entity)
      end

      def entity_has_subgroups?(entity)
        entity_children(entity).any? do |child|
          child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
      end

      def entity_has_faces?(entity)
        entity_children(entity).any? { |child| child.is_a?(Sketchup::Face) }
      end

      def sort_containers_for_scan(containers)
        indexed = containers.each_with_index.map { |container, index| [container, index] }
        indexed.sort do |(left, left_index), (right, right_index)|
          left_priority = container_scan_priority(left)
          right_priority = container_scan_priority(right)
          if left_priority == right_priority
            left_index <=> right_index
          else
            left_priority <=> right_priority
          end
        end.map(&:first)
      end

      def container_scan_priority(container)
        return 0 if structure_container?(container)
        return 1 if container_name_priority(container) <= 1

        2
      end

      def structure_container?(container)
        child_groups = []
        entity_children(container).each do |child|
          child_groups << child if child.is_a?(Sketchup::Group) || child.is_a?(Sketchup::ComponentInstance)
        end
        return false if child_groups.empty?

        child_groups.all? { |child| piece_entity?(child) }
      end

      def container_name_priority(container)
        name = container.name.to_s.downcase
        return 0 if name.include?('estructura') || name.include?('estruct') || name.include?('cuerpo')
        return 2 if name.include?('cajon') || name.include?('caj')

        1
      end

      def group_pieces_by_dimensions(pieces)
        counts = {}
        order = []

        pieces.each do |piece|
          begin
            dims = DimHelpers.piece_dimensions_mm(piece)
            key = [dims[:length], dims[:width], dims[:thickness]].sort { |a, b| b <=> a }
            unless counts.key?(key)
              counts[key] = 0
              order << key
            end
            counts[key] += 1
          rescue ArgumentError
            next
          end
        end

        order.map do |(length, width, thickness)|
          {
            count: counts[[length, width, thickness]],
            length: length,
            width: width,
            thickness: thickness
          }
        end
      end
    end

    unless file_loaded?(__FILE__)
      toolbar = UI::Toolbar.new('Despiece PRO')
      menu = UI.menu('Extensions')

      cmd_scan = UI::Command.new('Escanear Modulo') do
        Sketchup.active_model.select_tool(BiraEstudio::DespiecePro::ScanModuleTool.new)
      end
      cmd_scan.small_icon = File.join(PLUGIN_DIR, 'icons', 'scan_small.png')
      cmd_scan.large_icon = File.join(PLUGIN_DIR, 'icons', 'scan_large.png')
      cmd_scan.tooltip = 'Escanear Modulo MDF'
      cmd_scan.status_bar_text = 'Click en un grupo que contenga piezas MDF para agregarlas a la lista'
      cmd_scan.menu_text = 'Escanear Modulo'
      toolbar.add_item(cmd_scan)
      menu.add_item(cmd_scan)

      cmd_list = UI::Command.new('Ver Lista') do
        BiraEstudio::DespiecePro::ListDialog.toggle
      end
      cmd_list.small_icon = File.join(PLUGIN_DIR, 'icons', 'list_small.png')
      cmd_list.large_icon = File.join(PLUGIN_DIR, 'icons', 'list_large.png')
      cmd_list.tooltip = 'Ver Lista de piezas'
      cmd_list.status_bar_text = 'Abre o cierra la ventana con la lista acumulada de piezas'
      cmd_list.menu_text = 'Ver Lista'
      toolbar.add_item(cmd_list)
      menu.add_item(cmd_list)

      toolbar.restore
      Store.restore_from_model(Sketchup.active_model)
      file_loaded(__FILE__)
    end
  end
end
