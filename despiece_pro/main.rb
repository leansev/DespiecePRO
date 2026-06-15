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
      @scanned_ids = []
      @scanned_entities = []
      SCAN_MATERIAL_NAME = 'DespiecePRO_escaneado'.freeze
      DEFAULT_BADGE_COLOR = '#ff941f'.freeze

      class << self
        attr_reader :modules, :scanned_entities

        def add_module(name, pieces, entity_id)
          @modules << {
            name: name,
            entity_id: entity_id,
            pieces: pieces,
            piece_names: {},
            badge_color: DEFAULT_BADGE_COLOR
          }
        end

        def find_module_by_entity_id(entity_id)
          entity_id = entity_id.to_i
          @modules.find { |entry| entry[:entity_id] == entity_id }
        end

        def update_module_name(entity_id, name)
          entry = find_module_by_entity_id(entity_id)
          return unless entry

          name = name.to_s.strip
          name = 'Grupo sin nombre' if name.empty?
          entry[:name] = name
        end

        def update_piece_name(entity_id, dim_key, name)
          entry = find_module_by_entity_id(entity_id)
          return unless entry

          entry[:piece_names] ||= {}
          name = name.to_s.strip
          if name.empty?
            entry[:piece_names].delete(dim_key.to_s)
          else
            entry[:piece_names][dim_key.to_s] = name
          end
        end

        def update_module_badge_color(entity_id, color)
          entry = find_module_by_entity_id(entity_id)
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
          entity_id = entry[:entity_id]
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

          '<div class="module" data-entity-id="' + entity_id.to_s + '">' +
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

        def scanned?(entity_id)
          @scanned_ids.include?(entity_id)
        end

        def mark_scanned(entity)
          entity_id = entity.entityID
          return if @scanned_ids.include?(entity_id)

          @scanned_ids << entity_id
          @scanned_entities << entity
        end

        def remove_module(entity_id)
          entity_id = entity_id.to_i
          entry = find_module_by_entity_id(entity_id)
          return unless entry

          @modules.delete(entry)
          @scanned_ids.delete(entity_id)
          @scanned_entities.delete_if do |entity|
            !entity.valid? || entity.entityID == entity_id
          end

          model = Sketchup.active_model
          view = model.active_view if model
          view.invalidate if view
        end

        def clear!
          model = Sketchup.active_model
          cleanup_scan_materials(model) if model
          @modules.clear
          @scanned_ids.clear
          @scanned_entities.clear

          view = model.active_view if model
          view.invalidate if view
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
            rows << {
              'type' => 'module',
              'label' => "\u2014 #{entry[:name]} \u2014"
            }

            entry[:pieces].each do |piece|
              dim_key = piece_dim_key(piece[:length], piece[:width], piece[:thickness])
              piece_name = (entry[:piece_names] || {})[dim_key].to_s.strip
              piece_name = 'Pieza' if piece_name.empty?

              rows << {
                'type' => 'piece',
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

          rows << {
            'type' => 'total',
            'label' => "TOTAL DE PIEZAS: #{total_pieces}"
          }

          { 'rows' => rows }
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

    module SpreadsheetExport
      HEADERS = [
        'cantidad',
        'LARGO',
        'ANCHO',
        'nombre',
        'rota',
        'canto_arr',
        'canto_aba',
        'canto_izq',
        'canto_der'
      ].freeze

      module_function

      def build_rows
        rows = [HEADERS.dup]

        Store.export_payload['rows'].each do |item|
          case item['type']
          when 'module', 'total'
            row = [item['label'].to_s]
            (HEADERS.length - 1).times { row << '' }
            rows << row
          when 'piece'
            rows << [
              item['cantidad'],
              item['largo'],
              item['ancho'],
              item['nombre'],
              item['rota'],
              item['canto_arr'],
              item['canto_aba'],
              item['canto_izq'],
              item['canto_der']
            ]
          end
        end

        rows
      end

      def xml_escape(text)
        text.to_s
            .gsub('&', '&amp;')
            .gsub('<', '&lt;')
            .gsub('>', '&gt;')
            .gsub('"', '&quot;')
            .gsub("'", '&apos;')
      end

      def column_letter(index)
        index += 1
        letters = ''
        while index > 0
          index, remainder = (index - 1).divmod(26)
          letters = (65 + remainder).chr + letters
        end
        letters
      end

      def numeric_cell?(value)
        value.is_a?(Numeric) || value.to_s =~ /\A-?\d+\z/
      end

      def cell_xml(column_index, row_index, value)
        reference = "#{column_letter(column_index)}#{row_index}"
        if numeric_cell?(value)
          "<c r=\"#{reference}\"><v>#{value.to_s}</v></c>"
        else
          text = xml_escape(value)
          "<c r=\"#{reference}\" t=\"inlineStr\"><is><t>#{text}</t></is></c>"
        end
      end

      def sheet_xml(rows)
        body = rows.each_with_index.map do |row, row_index|
          cells = row.each_with_index.map do |value, column_index|
            next if value.nil? || value.to_s.empty?

            cell_xml(column_index, row_index + 1, value)
          end.compact.join

          "<row r=\"#{row_index + 1}\">#{cells}</row>"
        end.join

        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' \
          "<sheetData>#{body}</sheetData></worksheet>"
      end

      def xlsx_entries(rows)
        {
          '[Content_Types].xml' => content_types_xml,
          '_rels/.rels' => root_rels_xml,
          'xl/workbook.xml' => workbook_xml,
          'xl/_rels/workbook.xml.rels' => workbook_rels_xml,
          'xl/worksheets/sheet1.xml' => sheet_xml(rows),
          'xl/styles.xml' => styles_xml
        }
      end

      def content_types_xml
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' \
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' \
          '<Default Extension="xml" ContentType="application/xml"/>' \
          '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' \
          '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' \
          '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>' \
          '</Types>'
      end

      def root_rels_xml
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' \
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' \
          '</Relationships>'
      end

      def workbook_xml
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' \
          '<sheets><sheet name="Despiece" sheetId="1" r:id="rId1"/></sheets></workbook>'
      end

      def workbook_rels_xml
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' \
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>' \
          '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' \
          '</Relationships>'
      end

      def styles_xml
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' \
          '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' \
          '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>' \
          '<fills count="1"><fill><patternFill patternType="none"/></fill></fills>' \
          '<borders count="1"><border/></borders>' \
          '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' \
          '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>' \
          '</styleSheet>'
      end

      def csv_line(values)
        values.map { |value| csv_field(value) }.join(',')
      end

      def csv_field(value)
        text = value.nil? ? '' : value.to_s
        if text.include?(',') || text.include?('"') || text.include?("\n") || text.include?("\r")
          '"' + text.gsub('"', '""') + '"'
        else
          text
        end
      end
    end

    module ZipArchiveWriter
      module_function

      def write(path, entries)
        if zip_gem_available?
          write_with_zip_gem(path, entries)
        else
          write_with_zlib(path, entries)
        end
      end

      def zip_gem_available?
        return @zip_gem_available unless @zip_gem_available.nil?

        begin
          require 'zip'
          @zip_gem_available = true
        rescue LoadError
          @zip_gem_available = false
        end

        @zip_gem_available
      end

      def write_with_zip_gem(path, entries)
        require 'zip'
        File.delete(path) if File.exist?(path)

        Zip::File.open(path, Zip::File::CREATE) do |zipfile|
          entries.each do |name, content|
            zipfile.get_output_stream(name) { |stream| stream.write(content.to_s) }
          end
        end
      end

      def write_with_zlib(path, entries)
        require 'zlib'

        File.open(path, 'wb') do |io|
          offsets = []
          entries.each do |name, content|
            content = content.to_s
            offsets << write_local_entry(io, name, content)
          end

          central_offset = io.tell
          entries.each_with_index do |(name, content), index|
            write_central_entry(io, name, content.to_s, offsets[index])
          end

          central_size = io.tell - central_offset
          write_end_of_central_directory(io, entries.length, central_size, central_offset)
        end
      end

      def write_local_entry(io, name, data)
        offset = io.tell
        name_bytes = name.to_s.encode('UTF-8')
        crc = Zlib.crc32(data)
        size = data.bytesize
        io.write([0x04034b50, 20, 0, 0, 0, 0, crc, size, size, name_bytes.bytesize, 0].pack('VvvvvvVVvv'))
        io.write(name_bytes)
        io.write(data)
        offset
      end

      def write_central_entry(io, name, data, offset)
        name_bytes = name.to_s.encode('UTF-8')
        crc = Zlib.crc32(data)
        size = data.bytesize
        io.write([0x02014b50, 20, 20, 0, 0, 0, 0, crc, size, size, name_bytes.bytesize, 0, 0, 0, 0, 0, offset].pack('VvvvvvvVVvvvvVVV'))
        io.write(name_bytes)
      end

      def write_end_of_central_directory(io, count, central_size, central_offset)
        io.write([0x06054b50, 0, 0, count, count, central_size, central_offset, 0].pack('VvvvvVVv'))
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

          if xlsx_export_available?
            path = UI.savepanel('Guardar Excel', '', 'despiece.xlsx')
            return unless path

            path = normalize_extension(path, '.xlsx')
            if write_xlsx(path)
              Sketchup.status_text = "Excel exportado: #{path}"
            else
              show_export_error
            end
          else
            path = UI.savepanel('Guardar CSV', '', 'despiece.csv')
            return unless path

            path = normalize_extension(path, '.csv')
            if write_csv(path)
              Sketchup.status_text = "CSV exportado: #{path}"
            else
              show_export_error
            end
          end
        end

        def xlsx_export_available?
          ZipArchiveWriter.zip_gem_available? || zlib_available?
        rescue StandardError
          false
        end

        def zlib_available?
          require 'zlib'
          true
        rescue LoadError
          false
        end

        def normalize_extension(path, extension)
          path = path.to_s
          return path if path.downcase.end_with?(extension)

          path + extension
        end

        def write_xlsx(path)
          @last_error = nil
          rows = SpreadsheetExport.build_rows
          entries = SpreadsheetExport.xlsx_entries(rows)
          ZipArchiveWriter.write(path, entries)

          File.exist?(path) && File.size?(path).to_i > 0
        rescue StandardError => e
          @last_error = "#{e.class}: #{e.message}"
          false
        end

        def write_csv(path)
          @last_error = nil
          rows = SpreadsheetExport.build_rows
          content = rows.map { |row| SpreadsheetExport.csv_line(row) }.join("\r\n")
          bom = "\xEF\xBB\xBF"

          File.open(path, 'wb') do |handle|
            handle.write(bom)
            handle.write(content)
          end

          File.exist?(path) && File.size?(path).to_i > 0
        rescue StandardError => e
          @last_error = "#{e.class}: #{e.message}"
          false
        end

        def show_export_error
          detail = last_error.to_s.strip
          detail = 'Error desconocido.' if detail.empty?
          UI.messagebox("No se pudo exportar el archivo.\n\n#{detail}")
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
          @dialog ||= build_dialog
          @dialog.set_html(dialog_body_html)
          @dialog.show
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

        if Store.scanned?(entity.entityID)
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

        Store.mark_scanned(entity)
        Store.add_module(module_name, grouped, entity.entityID)
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
      file_loaded(__FILE__)
    end
  end
end
