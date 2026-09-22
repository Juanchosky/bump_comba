// DESBLOQUEO ADAPTATIVO EN DOS PASADAS
//
// QUE ARREGLA
//
// Los "pixelitos" de estas fuentes son macrobloques: el codificador del
// proveedor troceo la imagen en cuadrados de 16x16 y, con poco bitrate, cada
// cuadrado se queda con un valor casi plano. El resultado es un damero
// visible, sobre todo en zonas lisas —cielos, paredes, pieles, fundidos—
// porque ahi no hay detalle que lo tape.
//
// Esa informacion esta destruida y no se puede recuperar. Lo que si se puede
// es que el damero deje de verse.
//
// POR QUE DOS PASADAS Y NO UNA MAS GRANDE
//
// Para aplanar la frontera entre dos bloques planos hay que llegar a la mitad
// del bloque, unos 8 pixeles. Un vecindario 2D de +-8 son 17x17 = 289 tomas
// por pixel: inviable. Separado en dos pasadas de una dimension —primero
// horizontal, luego vertical— son 11 tomas cada una, 22 en total, y cubren el
// mismo 17x17.
//
// Un bilateral no es separable en sentido estricto —el peso de rango rompe la
// separabilidad— pero la aproximacion separable es la practica habitual en
// tiempo real y visualmente se comporta igual.
//
// ── LAS CUATRO COMPUERTAS, Y POR QUE HACEN FALTA LAS CUATRO ────────────────────
//
// 1. `rango` pesa cada vecino por lo PARECIDO que es al pixel central. Con un
//    alcance de 8 px muchas tomas caen al otro lado de un borde, y el peso de
//    rango las anula. Sin esto, una reja tan ancha convertiria cada borde en
//    una mancha.
//
// 2. `planitud` mira el salto del vecindario inmediato y apaga la pasada donde
//    hay un borde de verdad. En un filtro separable cae de maravilla: la
//    pasada horizontal mide en horizontal, asi que un borde VERTICAL la apaga
//    —lo que se quiere— y deja pasar la vertical, que ahi no tiene nada que
//    estropear.
//
// 3. `textura` — LA TERCERA, Y LA QUE SE AÑADIO DESPUES DE PROBARLO.
//
//    Con las dos primeras el damero desaparecia, pero la respuesta fue "ahora
//    se ve como nublado". Y con razon: las dos miran la AMPLITUD del salto, y
//    un escalon de macrobloque y el grano de una piel tienen amplitudes
//    parecidas. Todo lo que estuviera por debajo del umbral se promediaba,
//    textura fina incluida, y comerse la microtextura de una imagen entera es
//    exactamente lo que se ve como un velo por encima.
//
//    Pero hay una diferencia FISICA que si los separa: un macrobloque es un
//    ESCALON —plano, salto, plano— y la textura OSCILA. Se mide como un
//    COCIENTE: cuanta de la variacion local va en una sola direccion.
//
//      · Frontera de bloque   [0, 0, 0, 10, 10]  -> 10/10 = 1,00  filtrar
//      · Degradado de cielo   [0, 2, 4,  6,  8]  ->  8/8  = 1,00  filtrar
//      · Grano, tela, poros   [0, 4,-2,  5, -3]  ->  3/25 = 0,12  no tocar
//
//    Que sea un cociente es lo importante: NO depende de la amplitud. La
//    primera version usaba un umbral absoluto (~1 nivel de 255) y por eso se
//    comia la microtextura mas fina — la piel, sobre todo, que es justo la
//    que se nota cuando falta ("se ven como con maquillaje", 2026-09-21).
//
// 4. `reja` — LA CUARTA, Y LA QUE MAS CAMBIA EL RESULTADO.
//
//    El fallo de fondo de las tres anteriores era filtrar los 921.600 pixeles
//    por igual. Y con SIGMA = 0,09, un vecino que se diferencia en 4 niveles
//    pesa 0,985: dentro de una cara TODOS los pixeles entran con peso casi
//    entero, asi que el bilateral degenera en una gaussiana de radio 8. Las
//    otras compuertas eran lo unico que separaba un rostro de un desenfoque,
//    y no daban abasto. Bajar SIGMA no vale: tiene que llegar a ~23 niveles
//    para aplanar el escalon.
//
//    La salida es lo que hacen H.264 y HEVC en su propio desbloqueo: filtrar
//    SOLO SOBRE LA REJILLA. En el interior de un bloque no hay ninguna
//    frontera que borrar, solo detalle que perder. Las fronteras son el 12%
//    de la imagen; el otro 88% se estaba emborronando para nada.
//
//    No es un corte seco sino un suelo (SUELO_FUERA = 0,25): si el flujo no
//    estuviera alineado a 16 px —un recorte raro, otro tamaño de bloque— el
//    filtro sigue actuando a un cuarto en vez de desaparecer.
//
// POR QUE ENGANCHA EN `LUMA` Y NO EN `MAIN`
//
// En LUMA el fotograma esta todavia en su tamaño original —720p o menos— asi
// que la reja de macrobloques esta donde de verdad esta, sin estirar. Y son
// 921.600 pixeles en vez de los 2.073.600 de la salida a 1080p.
//
// Solo luma porque ahi es donde se ve el damero. El croma de estas fuentes
// esta a un cuarto de resolucion y lo que tiene son manchas de color.
//
// SI HAY QUE AJUSTARLO, en este orden y SIEMPRE en las dos pasadas (que una
// quede mas fuerte que la otra se ve como estrias):
//   · Vuelven los cuadros    -> subir ANCHO_REJA a 3,0; luego SIGMA.
//   · Se ve nublado          -> bajar SUELO_FUERA (0,25 -> 0,10).
//   · Caras de plastico      -> bajar MONO_ALTA (protege textura antes).
//   · Se ve de plastico      -> bajar FUERZA.
//   · Halos junto a bordes   -> subir BORDE_BAJO.

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 1/2 - horizontal

// Cuanto del promedio entra en la zona mas plana, por pasada. Las dos pasadas
// se componen, asi que el efecto total es mayor que este numero.
#define FUERZA 0.95

// Umbral de "estos dos vecinos son el mismo color, con la compresion de por
// medio". En unidades de luma (0..1): 0,09 son ~23 niveles de 255, el tamaño
// tipico de un escalon de macrobloque a bitrate corto.
#define SIGMA 0.09

// Caida del peso por distancia, en pixeles. 4,0 deja que la toma de +-8 pese
// todavia 0,14: poco, pero lo justo para arrastrar el valor del bloque vecino
// y aplanar el escalon.
#define SIGMA_ESPACIAL 3.0

// Donde empieza y acaba de apagarse la pasada por amplitud del salto.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

// Cuanta de la variacion local tiene que ir en una sola direccion para dar el
// vecindario por estructura (escalon o degradado) y filtrarlo. Por debajo de
// MONO_BAJA es textura y no se toca.
#define MONO_BAJA 0.35
#define MONO_ALTA 0.75

// Variacion por debajo de la cual el vecindario se da por plano del todo: no
// hay textura que proteger, asi que se filtra entero.
#define PLANO_TOTAL 0.002

// La rejilla del codificador, y cuanto se sigue filtrando fuera de ella.
#define REJA 16.0
#define ANCHO_REJA 4.0
#define SUELO_FUERA 0.15

// Cuanto filtrar en esta coordenada, segun lo cerca que caiga de una frontera
// de macrobloque. `c` es la coordenada del pixel EN EL EJE DE ESTA PASADA: la
// pasada horizontal mira columnas y la vertical, filas.
float enLaReja(float c) {
    float dentro = mod(c, REJA);
    float distancia = min(dentro, REJA - dentro);
    float cerca = 1.0 - smoothstep(ANCHO_REJA, ANCHO_REJA + 2.0, distancia);
    return SUELO_FUERA + (1.0 - SUELO_FUERA) * cerca;
}

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    // ── EL RACIMO CERCANO, EN ORDEN ─────────────────────────────────────
    // Cinco muestras consecutivas. Sirven para las tres cosas a la vez: el
    // promedio, la compuerta de amplitud y la de oscilacion.
    float m2 = HOOKED_texOff(vec2(-2.0, 0.0)).x;
    float m1 = HOOKED_texOff(vec2(-1.0, 0.0)).x;
    float p1 = HOOKED_texOff(vec2(1.0, 0.0)).x;
    float p2 = HOOKED_texOff(vec2(2.0, 0.0)).x;

    // Amplitud: solo el anillo de radio 1. Medirla en todo el alcance de 8 px
    // apagaria el filtro en cualquier zona lisa con un borde a media docena
    // de pixeles, y las cercanias de los bordes son donde la compresion deja
    // mas basura.
    float mayorSaltoCerca = max(abs(m1 - centro), abs(p1 - centro));

    // Oscilacion: cambios de sentido en las diferencias consecutivas.
    // MONOTONIA: cuanta de la variacion del vecindario va en UNA sola
    // direccion. Es un cociente, asi que NO depende de la amplitud: funciona
    // igual con un escalon de 23 niveles que con poros de 2. El umbral
    // absoluto de antes decidia por amplitud, y por eso se comia la
    // microtextura mas fina.
    //
    //   escalon  [0,0,0,9,9]   -> variacion 9,  neta 9 -> 1,00 (filtrar)
    //   grano    [0,4,-2,5,-3] -> variacion 25, neta 3 -> 0,12 (no tocar)
    float d1 = m1 - m2;
    float d2 = centro - m1;
    float d3 = p1 - centro;
    float d4 = p2 - p1;
    float variacion = abs(d1) + abs(d2) + abs(d3) + abs(d4);
    float neta = abs(d1 + d2 + d3 + d4);
    // Si no varia NADA no hay textura que proteger: filtrar sale gratis.
    float monotonia = variacion < PLANO_TOTAL ? 1.0 : neta / variacion;

    // ── EL PROMEDIO BILATERAL ───────────────────────────────────────────
    float acumulado = centro;
    float pesos = 1.0;

    float w1 = exp(-1.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
    float wm1 = w1 * exp(-((m1 - centro) * (m1 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    float wp1 = w1 * exp(-((p1 - centro) * (p1 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    acumulado += m1 * wm1 + p1 * wp1;
    pesos += wm1 + wp1;

    float w2 = exp(-4.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
    float wm2 = w2 * exp(-((m2 - centro) * (m2 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    float wp2 = w2 * exp(-((p2 - centro) * (p2 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    acumulado += m2 * wm2 + p2 * wp2;
    pesos += wm2 + wp2;

    // Y el resto del alcance: +-4, +-6, +-8.
    //
    // Los desplazamientos se CALCULAN, no se leen de un array: el constructor
    // de arrays necesita GLSL ES 3.0 y MPV tiene mensajes del tipo
    // "Disabling debanding (GLSL version too old)", o sea que hay aparatos con
    // version mas vieja donde el shader no compilaria entero.
    for (int k = 2; k <= 4; k++) {
        float d = float(k) * 2.0;
        float espacial = exp(-(d * d) /
                             (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
        float a = HOOKED_texOff(vec2(-d, 0.0)).x;
        float b = HOOKED_texOff(vec2(d, 0.0)).x;
        float wa = espacial * exp(-((a - centro) * (a - centro)) /
                                  (2.0 * SIGMA * SIGMA));
        float wb = espacial * exp(-((b - centro) * (b - centro)) /
                                  (2.0 * SIGMA * SIGMA));
        acumulado += a * wa + b * wb;
        pesos += wa + wb;
    }

    float promedio = acumulado / max(pesos, 1e-6);

    float planitud = 1.0 - smoothstep(BORDE_BAJO, BORDE_ALTO, mayorSaltoCerca);
    float estructura = smoothstep(MONO_BAJA, MONO_ALTA, monotonia);
    float reja = enLaReja(HOOKED_pos.x * HOOKED_size.x);

    return vec4(
        mix(centro, promedio, planitud * estructura * reja * FUERZA),
        0.0, 0.0, 1.0
    );
}

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 2/2 - vertical

// Los mismos valores que la pasada horizontal. Si se cambia uno hay que
// cambiar los dos: son las dos mitades del MISMO filtro, y descuadrarlos deja
// un desbloqueo mas fuerte en un eje que en el otro, que se ve como estrias.
#define FUERZA 0.95
#define SIGMA 0.09
#define SIGMA_ESPACIAL 3.0
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32
// Cuanta de la variacion local tiene que ir en una sola direccion para dar el
// vecindario por estructura (escalon o degradado) y filtrarlo. Por debajo de
// MONO_BAJA es textura y no se toca.
#define MONO_BAJA 0.35
#define MONO_ALTA 0.75

// Variacion por debajo de la cual el vecindario se da por plano del todo: no
// hay textura que proteger, asi que se filtra entero.
#define PLANO_TOTAL 0.002

// La rejilla del codificador, y cuanto se sigue filtrando fuera de ella.
#define REJA 16.0
#define ANCHO_REJA 4.0
#define SUELO_FUERA 0.15

// Cuanto filtrar en esta coordenada, segun lo cerca que caiga de una frontera
// de macrobloque. `c` es la coordenada del pixel EN EL EJE DE ESTA PASADA: la
// pasada horizontal mira columnas y la vertical, filas.
float enLaReja(float c) {
    float dentro = mod(c, REJA);
    float distancia = min(dentro, REJA - dentro);
    float cerca = 1.0 - smoothstep(ANCHO_REJA, ANCHO_REJA + 2.0, distancia);
    return SUELO_FUERA + (1.0 - SUELO_FUERA) * cerca;
}

vec4 hook() {
    // OJO: `HOOKED` aqui ES LA SALIDA DE LA PASADA ANTERIOR. MPV encadena los
    // hooks del mismo punto en el orden del archivo, asi que esta pasada
    // trabaja sobre la imagen ya desbloqueada en horizontal. De ahi sale el
    // vecindario efectivo de 17x17 con solo 22 tomas.
    float centro = HOOKED_tex(HOOKED_pos).x;

    float m2 = HOOKED_texOff(vec2(0.0, -2.0)).x;
    float m1 = HOOKED_texOff(vec2(0.0, -1.0)).x;
    float p1 = HOOKED_texOff(vec2(0.0, 1.0)).x;
    float p2 = HOOKED_texOff(vec2(0.0, 2.0)).x;

    float mayorSaltoCerca = max(abs(m1 - centro), abs(p1 - centro));

    // MONOTONIA: cuanta de la variacion del vecindario va en UNA sola
    // direccion. Es un cociente, asi que NO depende de la amplitud: funciona
    // igual con un escalon de 23 niveles que con poros de 2. El umbral
    // absoluto de antes decidia por amplitud, y por eso se comia la
    // microtextura mas fina.
    //
    //   escalon  [0,0,0,9,9]   -> variacion 9,  neta 9 -> 1,00 (filtrar)
    //   grano    [0,4,-2,5,-3] -> variacion 25, neta 3 -> 0,12 (no tocar)
    float d1 = m1 - m2;
    float d2 = centro - m1;
    float d3 = p1 - centro;
    float d4 = p2 - p1;
    float variacion = abs(d1) + abs(d2) + abs(d3) + abs(d4);
    float neta = abs(d1 + d2 + d3 + d4);
    // Si no varia NADA no hay textura que proteger: filtrar sale gratis.
    float monotonia = variacion < PLANO_TOTAL ? 1.0 : neta / variacion;

    float acumulado = centro;
    float pesos = 1.0;

    float w1 = exp(-1.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
    float wm1 = w1 * exp(-((m1 - centro) * (m1 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    float wp1 = w1 * exp(-((p1 - centro) * (p1 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    acumulado += m1 * wm1 + p1 * wp1;
    pesos += wm1 + wp1;

    float w2 = exp(-4.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
    float wm2 = w2 * exp(-((m2 - centro) * (m2 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    float wp2 = w2 * exp(-((p2 - centro) * (p2 - centro)) /
                         (2.0 * SIGMA * SIGMA));
    acumulado += m2 * wm2 + p2 * wp2;
    pesos += wm2 + wp2;

    for (int k = 2; k <= 4; k++) {
        float d = float(k) * 2.0;
        float espacial = exp(-(d * d) /
                             (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
        float a = HOOKED_texOff(vec2(0.0, -d)).x;
        float b = HOOKED_texOff(vec2(0.0, d)).x;
        float wa = espacial * exp(-((a - centro) * (a - centro)) /
                                  (2.0 * SIGMA * SIGMA));
        float wb = espacial * exp(-((b - centro) * (b - centro)) /
                                  (2.0 * SIGMA * SIGMA));
        acumulado += a * wa + b * wb;
        pesos += wa + wb;
    }

    float promedio = acumulado / max(pesos, 1e-6);

    float planitud = 1.0 - smoothstep(BORDE_BAJO, BORDE_ALTO, mayorSaltoCerca);
    float estructura = smoothstep(MONO_BAJA, MONO_ALTA, monotonia);
    float reja = enLaReja(HOOKED_pos.y * HOOKED_size.y);

    return vec4(
        mix(centro, promedio, planitud * estructura * reja * FUERZA),
        0.0, 0.0, 1.0
    );
}

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 3/3 - nitidez y grano

// ── POR QUE HACE FALTA UNA TERCERA PASADA ──────────────────────────────────
//
// Con las dos primeras desaparecieron los cuadros, pero la respuesta fue "se
// ve borroso o desenfocado, y no estaria mal un poquitito de granulado".
//
// Las dos cosas son el mismo problema visto por dos lados. Un desbloqueador,
// por listo que sea, RESTA microcontraste: donde decide que hay un escalon
// promedia, y promediar es exactamente lo contrario de definir. Y una imagen
// sin ningun ruido en las zonas lisas se lee como plana, como plastico — por
// eso el cine conserva el grano a proposito.
//
// Asi que esta pasada devuelve las dos: microcontraste donde hay detalle de
// verdad, y un grano minimo donde no lo hay.
//
// ── POR QUE NO ES UN `sharpen` DE MPV ──────────────────────────────────────
//
// `sharpen` de mpv es ciego: aplica el mismo realce a todo. Sobre este
// material realzaria tambien los restos de macrobloque que acabamos de
// quitar, y devolveria los cuadros por la puerta de atras. Aqui el realce va
// con las mismas compuertas que el desbloqueo, pero AL REVES:
//
//   · Donde el desbloqueo actuo (plano) -> NO se realza, se pone grano.
//   · Donde el desbloqueo se aparto (textura) -> SI se realza.
//
// Son complementarios por construccion, no por casualidad: la misma medida de
// oscilacion decide las dos cosas, asi que ninguna zona recibe las dos.

// Cuanto microcontraste se devuelve. 0,45 es medio realce: suficiente para
// que una cara deje de verse de cera, poco para que no chille.
// QUE SIGNIFICA ESTE NUMERO, para poder pedirlo en porcentaje.
//
// Es directamente la FRACCION DEL DETALLE que se devuelve: 0,80 son un 80%,
// 1,44 son un 144%. Por encima de 1,0 se esta añadiendo MAS microcontraste
// del que el pixel tenia, que es lo que en television llaman "realce" y en
// fotografia "sobreenfoque" — legitimo mientras no chille.
//
// Recorrido: 0,45 (original) -> 0,55 -> 0,80 -> 1,44 (+80% a peticion,
// 2026-09-21).
//
// Se puede subir con menos miedo que un realce normal por dos motivos:
//  · Va multiplicado por `textura`, asi que entra donde hay detalle de verdad
//    y se queda en CERO sobre los restos de macrobloque — que es justo lo que
//    un `sharpen` ciego realzaria de vuelta.
//  · El recorte al rango de los vecinos (mas MARGEN_HALO) lo frena antes de
//    que pinte un contorno inventado.
//
// Si se ve crujiente, con filos o con textura de lija, ESTE es el mando. Si
// lo que se ven son aureolas junto a los bordes, el mando es MARGEN_HALO.
#define NITIDEZ 1.65

// Tope del realce, en unidades de luma. Un detalle mas grande que esto ya es
// un borde de verdad y no necesita ayuda; dejarlo suelto es lo que produce
// los halos blancos junto a los contornos.
#define TOPE_DETALLE 0.06

// Cuanto puede asomar el pixel realzado fuera del rango de sus vecinos, en
// tanto por uno de ese rango. 0 es el recorte estricto de antes —seguro pero
// sordo al mando de NITIDEZ—; 0,25 da filo sin llegar al halo, que aparece
// cuando el realce se sale mucho y pinta un contorno que no estaba.
// Si se ven bordes con aureola, bajar esto antes que NITIDEZ.
#define MARGEN_HALO 0.30

// Cuanto grano. 0,006 son ~1,5 niveles de 255: por debajo del umbral de
// "esto tiene ruido" y por encima del de "esto esta muerto". Pedia un
// poquitito; esto es un poquitito.
#define GRANO 0.006

// Las mismas de las pasadas 1 y 2, para decidir que es plano y que textura.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32
// Las mismas de las pasadas 1 y 2, para decidir que es plano y que textura.
#define MONO_BAJA 0.35
#define MONO_ALTA 0.75
#define PLANO_TOTAL 0.002

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    // La cruz de radio 1 y 2, en los dos ejes: aqui ya no hay que separar,
    // porque el alcance es de 2 px y 8 tomas son baratas.
    float iz2 = HOOKED_texOff(vec2(-2.0, 0.0)).x;
    float iz1 = HOOKED_texOff(vec2(-1.0, 0.0)).x;
    float de1 = HOOKED_texOff(vec2(1.0, 0.0)).x;
    float de2 = HOOKED_texOff(vec2(2.0, 0.0)).x;
    float ar2 = HOOKED_texOff(vec2(0.0, -2.0)).x;
    float ar1 = HOOKED_texOff(vec2(0.0, -1.0)).x;
    float ab1 = HOOKED_texOff(vec2(0.0, 1.0)).x;
    float ab2 = HOOKED_texOff(vec2(0.0, 2.0)).x;

    // ── CUANTO DETALLE HAY AQUI ─────────────────────────────────────────
    // La oscilacion, medida en los dos ejes y quedandose con la mayor: una
    // reja fina puede oscilar solo en horizontal, y eso sigue siendo textura.
    // La misma monotonia de las pasadas 1 y 2, medida en los dos ejes y
    // quedandose con la MENOR: si en algun eje hay textura, hay textura. Una
    // reja fina puede oscilar solo en horizontal y sigue siendo detalle que
    // merece realce.
    float varH = abs(iz1 - iz2) + abs(centro - iz1) +
                 abs(de1 - centro) + abs(de2 - de1);
    float monoH = varH < PLANO_TOTAL ? 1.0 : abs(de2 - iz2) / varH;

    float varV = abs(ar1 - ar2) + abs(centro - ar1) +
                 abs(ab1 - centro) + abs(ab2 - ab1);
    float monoV = varV < PLANO_TOTAL ? 1.0 : abs(ab2 - ar2) / varV;

    // `textura` es lo contrario de `estructura`: 1 donde hay detalle de
    // verdad, que es justo donde este realce tiene algo que recuperar.
    float textura = 1.0 - smoothstep(MONO_BAJA, MONO_ALTA, min(monoH, monoV));

    float mayorSalto = max(max(abs(iz1 - centro), abs(de1 - centro)),
                           max(abs(ar1 - centro), abs(ab1 - centro)));
    float planitud = 1.0 - smoothstep(BORDE_BAJO, BORDE_ALTO, mayorSalto);

    // ── EL REALCE ───────────────────────────────────────────────────────
    // Mascara de desenfoque clasica: lo que el pixel tiene DE MAS respecto a
    // su entorno es el detalle, y se le suma otra parte de eso mismo.
    float entorno = (iz1 + de1 + ar1 + ab1) * 0.25;
    float detalle = centro - entorno;

    // Recortado, no escalado: un detalle de 0,02 se realza entero y uno de
    // 0,30 —un contorno— aporta lo mismo que uno de 0,06 y no mas. Asi el
    // realce entra en las texturas y se queda quieto en los bordes.
    detalle = clamp(detalle, -TOPE_DETALLE, TOPE_DETALLE);

    float realzado = centro + detalle * NITIDEZ * textura;

    // Red de seguridad contra halos: pase lo que pase, el pixel no puede
    // salirse del rango de sus vecinos inmediatos. Un realce que sobrepasa
    // ese rango es, por definicion, un contorno inventado.
    // El margen (MARGEN_HALO) es lo que hace que subir NITIDEZ se NOTE.
    //
    // Antes el recorte era al rango exacto de los vecinos, y eso ataba el
    // realce: por mucho que se subiera la ganancia, el pixel no podia pasar
    // del vecino mas claro, asi que a partir de cierto punto el mando dejaba
    // de hacer efecto. Se permite ahora asomar un poco por fuera —lo justo
    // para que un borde tenga filo— y se sigue cortando ahi, que es lo que
    // evita el halo blanco.
    float minimoLocal = min(min(iz1, de1), min(min(ar1, ab1), centro));
    float maximoLocal = max(max(iz1, de1), max(max(ar1, ab1), centro));
    float margen = (maximoLocal - minimoLocal) * MARGEN_HALO;
    realzado = clamp(realzado, minimoLocal - margen, maximoLocal + margen);

    // ── EL GRANO ────────────────────────────────────────────────────────
    // Solo donde la imagen quedo plana, que es donde se nota la ausencia y
    // donde ademas rompe las bandas que le queden al degradado.
    //
    // `random` lo pone mpv y cambia cada fotograma. Es importante que cambie:
    // un ruido fijo se pega a la pantalla y se ve como suciedad en el cristal,
    // no como grano.
    float semilla = fract(sin(dot(HOOKED_pos * vec2(1920.0, 1080.0) +
                                  vec2(random * 137.0, random * 311.0),
                                  vec2(12.9898, 78.233))) * 43758.5453);
    float ruido = semilla - 0.5;

    // Menos grano en negros y en blancos: en las sombras se ve como ruido
    // sucio y en las altas luces no se ve, asi que solo estorbaria.
    float visibilidad = 1.0 - abs(centro - 0.5) * 2.0;
    visibilidad = clamp(visibilidad, 0.0, 1.0);

    float salida = realzado +
                   ruido * GRANO * planitud * (1.0 - textura) * visibilidad;

    return vec4(clamp(salida, 0.0, 1.0), 0.0, 0.0, 1.0);
}
