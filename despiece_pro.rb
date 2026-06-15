# despiece_pro.rb
# Registrador de extension para SketchUp

require 'sketchup.rb'
require 'extensions.rb'

module BiraEstudio
  module DespiecePro
    EXTENSION = SketchupExtension.new('Despiece PRO', 'despiece_pro/main')
    EXTENSION.creator     = 'BiraEstudio'
    EXTENSION.description = 'Escanea modulos MDF, agrupa piezas por dimensiones y muestra la lista acumulada.'
    EXTENSION.version     = '1.0.0'
    EXTENSION.copyright   = '2024 BiraEstudio'
    Sketchup.register_extension(EXTENSION, true)
  end
end
