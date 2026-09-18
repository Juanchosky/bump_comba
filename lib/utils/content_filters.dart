class ContentFilters {
  // ── A QUE GENERO PERTENECE UNA CATEGORIA ──────────────────────────────────
  //
  // UNA SOLA REGLA PARA EL TELEFONO Y PARA EL TELEVISOR.
  //
  // Cada pantalla tenia la suya escrita a mano y no coincidian: el telefono
  // miraba diez palabras para las novelas y el televisor tres, asi que el mismo
  // titulo caia en sitios distintos segun donde lo miraras. Y no se notaba,
  // porque el telefono junta todo en "Todas las Telenovelas" mientras el
  // televisor enseña una fila POR CATEGORIA, con su nombre a la vista.
  //
  // El proveedor no marca el genero de ninguna forma: lo unico que hay es el
  // nombre de la categoria. Por eso esto es una lista de palabras y no algo
  // mas fino — pero al menos es UNA lista.

  /// Doramas y demas drama asiatico.
  ///
  /// Van APARTE de las telenovelas a proposito. El telefono los contaba como
  /// novela (`dorama` estaba en su lista) y el televisor no, y ninguna de las
  /// dos cosas se sostiene: son generos distintos y el publico no es el mismo.
  /// Al no ser novelas, se ven donde les toca por tipo — las series, en SERIES.
  static const List<String> clavesDorama = [
    'dorama',
    'k-drama',
    'kdrama',
    'dorama',
    'coreana',
    'coreano',
  ];

  static const List<String> _clavesNovela = [
    'novela',
    'soap',
    'turca',
    'turco',
    'telemundo',
    'televisa',
    'biblica',
    'bíblica',
    'pasion',
    'pasión',
  ];

  /// Ojo con lo que NO esta aqui: `disney`, `nick` y `nickelodeon`. Son
  /// catalogos MIXTOS —Disney+ son 43 series y 2 peliculas, y casi nada de eso
  /// es animacion—, y metian la plataforma entera en ANIMACION. Se quedan
  /// `pixar`, `crunchyroll`, `funimation` y `toonami`, que si son animacion de
  /// principio a fin.
  ///
  /// Tampoco esta `anim` a secas: cogia "Animales" y cualquier cosa que
  /// empezara igual.
  static const List<String> _clavesAnimacion = [
    'anime',
    'animad',
    'animacion',
    'animación',
    'cartoon',
    'caricatura',
    'dibujo',
    'manga',
    'kids',
    'infantil',
    'toonami',
    'crunchyroll',
    'funimation',
    'pixar',
  ];

  static bool _encaja(String categoria, List<String> claves) {
    final c = categoria.toLowerCase();
    return claves.any(c.contains);
  }

  /// Drama asiatico: ni telenovela ni animacion.
  static bool esCategoriaDorama(String categoria) =>
      _encaja(categoria, clavesDorama);

  /// Telenovela. Un nombre que hable de doramas NO cuenta, aunque lleve la
  /// palabra "novela" al lado ("Novelas y Doramas").
  static bool esCategoriaNovela(String categoria) =>
      !esCategoriaDorama(categoria) && _encaja(categoria, _clavesNovela);

  /// Animacion, anime y contenido infantil.
  static bool esCategoriaAnimacion(String categoria) =>
      _encaja(categoria, _clavesAnimacion);

  /// Si una categoria YA TIENE su propia seccion: telenovelas o animacion.
  ///
  /// El televisor enseña TELENOVELAS y ANIMACION como secciones del lateral,
  /// asi que una categoria de novelas o de anime no pinta nada ademas en
  /// PELICULAS o en SERIES: se lee como la misma fila repetida en dos sitios.
  /// Es la misma regla de "cada categoria en un solo sitio" que ya decidia
  /// entre PELICULAS y SERIES por el tipo que pesa mas.
  ///
  /// Los doramas NO entran: no tienen seccion propia, asi que su sitio son
  /// las SERIES.
  static bool tieneSeccionPropia(String categoria) =>
      esCategoriaNovela(categoria) || esCategoriaAnimacion(categoria);

  static const List<String> excludedCountries = [
    'arabia',
    'argentina',
    'australia',
    'austria',
    'alemania',
    'brasil',
    'belgium',
    'bolivia',
    'bulgaria',
    'canada',
    'chile',
    'china',
    'colombia',
    'costa rica',
    'cuba',
    'croacia',
    'dinamarca',
    'dominicana',
    'ecuador',
    'egipto',
    'españa',
    'estados unidos',
    'filipinas',
    'finlandia',
    'francia',
    'grecia',
    'guatemala',
    'holanda',
    'honduras',
    'hungria',
    'india',
    'indonesia',
    'iran',
    'iraq',
    'irlanda',
    'israel',
    'italia',
    'japon',
    'jordania',
    'korea',
    'kuwait',
    'libano',
    'libia',
    'marruecos',
    'mexico',
    'myanmar',
    'nicaragua',
    'nigeria',
    'noruega',
    'pakistan',
    'panama',
    'paraguay',
    'peru',
    'polonia',
    'portugal',
    'puerto rico',
    'qatar',
    'republica',
    'romania',
    'rusia',
    'salvador',
    'serbia',
    'singapur',
    'siria',
    'suecia',
    'suiza',
    'tailandia',
    'taiwan',
    'tunisia',
    'turquia',
    'ucrania',
    'uk',
    'uruguay',
    'usa',
    'venezuela',
    'vietnam',
    'yemen',
  ];

  static const List<String> excludedKeywords = [
    'apostarias',
    'adulto',
    'adultos',
    'xxx',
    '+18',
    '18+',
    '24/7',
    '24 7',
    '24-7',
    'canales exclusivos',
    'exclusivo',
    'en vivo',
    'live',
    'tv en vivo',
    'canales',
    'channel',
    'deportes',
    'sport',
    'futbol',
    'football',
    'eventos deportivos',
    'evento',
    'liga',
    'streaming',
    'gratis',
    'free tv',
    'test',
    'ppv',
    'lucha libre',
    'religion',
    'noticias',
    'news',
    'radio',
    'novela',
    'variedad',
    'uhd',
    'broadcast',
    'directo',
  ];

  static const List<String> seriesExclusions = [
    'novela',
    'noticia',
    'variedad',
    'deporte',
    'canales',
    'live',
    'uhd',
  ];

  static const List<Map<String, dynamic>> curatedSeriesSections = [
    {
      'title': 'Drama Coreano',
      'keywords': ['corea', 'korean', 'k-drama', 'kdrama', 'doramas coreanos'],
    },
    {
      'title': 'Drama Tailandés',
      'keywords': ['tailand', 'thai', 'lakorns'],
    },
    {
      'title': 'Romántico',
      'keywords': ['romantic', 'romantico', 'romance', 'amor'],
    },
    {
      'title': 'Anime',
      'keywords': ['anime', 'animacion japonesa', 'animes'],
    },
    {
      'title': 'Comedia',
      'keywords': ['comedia', 'comedy', 'humor', 'sitcom'],
    },
    {
      'title': 'Drama',
      'keywords': ['drama'],
    },
    {
      'title': 'Aventura',
      'keywords': ['aventura', 'adventure', 'accion'],
    },
    {
      'title': 'Terror',
      'keywords': ['terror', 'horror', 'miedo', 'suspenso'],
    },
    {
      'title': 'Ciencia Ficción',
      'keywords': [
        'ciencia ficcion',
        'sci-fi',
        'scifi',
        'science fiction',
        'ficcion',
      ],
    },
    {
      'title': 'Guerra',
      'keywords': ['guerra', 'war', 'militar', 'belica'],
    },
  ];

  static const List<Map<String, dynamic>> curatedNovelaSections = [
    {
      'title': 'Telenovelas Mexicanas',
      'keywords': ['mexican', 'mexico', 'televisa', 'azteca', 'mexicana'],
    },
    {
      'title': 'Telenovelas Colombianas',
      'keywords': ['colombian', 'colombia', 'rcn', 'caracol', 'colombiana'],
    },
    {
      'title': 'Novelas Españolas',
      'keywords': ['españa', 'spanish', 'española', 'espanola', 'rtve'],
    },
    {
      'title': 'Popular',
      'keywords': ['popular', 'top', 'mejor', 'exito', 'hit'],
    },
    {
      'title': 'Novelas Turcas',
      'keywords': ['turca', 'turco', 'turkish', 'turquia', 'turkey'],
    },
    {
      'title': 'Reality Shows',
      'keywords': ['reality', 'show', 'concurso', 'talent', 'competencia'],
    },
    {
      'title': 'Novelas Americanas',
      'keywords': ['americana', 'american', 'usa', 'estados unidos', 'gringa'],
    },
  ];

  static const List<Map<String, dynamic>> curatedAnimationSections = [
    {
      'title': 'Anime',
      'keywords': [
        'anime',
        'animes',
        'animacion japonesa',
        'japanese animation',
      ],
    },
    {
      'title': 'Disney & Pixar',
      'keywords': ['disney', 'pixar', 'walt disney'],
    },
    {
      'title': 'Caricaturas Clásicas',
      'keywords': [
        'cartoon',
        'caricatura',
        'looney',
        'tom y jerry',
        'scooby',
        'hanna barbera',
      ],
    },
    {
      'title': 'Anime de Acción',
      'keywords': [
        'dragon ball',
        'naruto',
        'one piece',
        'bleach',
        'attack on titan',
        'shingeki',
        'demon slayer',
        'kimetsu',
        'jujutsu',
      ],
    },
    {
      'title': 'Para Niños',
      'keywords': [
        'kids',
        'infantil',
        'nickelodeon',
        'nick',
        'paw patrol',
        'peppa',
        'bob esponja',
        'spongebob',
        'dora',
      ],
    },
    {
      'title': 'Películas Animadas',
      'keywords': [
        'animada',
        'animado',
        'animated',
        'animation',
        'dreamworks',
        'illumination',
        'ghibli',
        'studio ghibli',
      ],
    },
    {
      'title': 'Anime Romántico',
      'keywords': ['romance', 'romantico', 'love', 'shoujo', 'shojo'],
    },
    {
      'title': 'Superhéroes Animados',
      'keywords': [
        'marvel',
        'dc',
        'superman',
        'batman',
        'spider',
        'avenger',
        'hero',
        'heroe',
      ],
    },
  ];
}
