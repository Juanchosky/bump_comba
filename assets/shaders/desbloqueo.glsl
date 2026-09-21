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
// ── LAS TRES COMPUERTAS, Y POR QUE HACEN FALTA LAS TRES ────────────────────
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
//    ESCALON —plano, salto, plano— y la textura OSCILA. Asi que en vez de
//    mirar cuanto salta, se mira cuantas veces CAMBIA DE SENTIDO en el
//    vecindario cercano:
//
//      · Frontera de bloque   [0, 0, 0, 10, 10]  -> 0 cambios de signo.
//      · Degradado de cielo   [0, 2, 4,  6,  8]  -> 0 cambios de signo.
//      · Grano, tela, poros   [0, 4,-2,  5, -3]  -> 3 cambios de signo.
//
//    Con 0 o 1 cambios el filtro entra entero; con 3 se apaga. Los dos
//    primeros casos son justo los que hay que arreglar y el tercero es justo
//    el que habia que dejar en paz.
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
//   · Vuelven los cuadros   -> subir SIGMA, y BORDE_ALTO si hace falta.
//   · Sigue nublado          -> bajar OSC_ALTA (apaga el filtro antes).
//   · Se ve de plastico      -> bajar FUERZA.
//   · Halos junto a bordes   -> subir BORDE_BAJO.

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 1/2 - horizontal

// Cuanto del promedio entra en la zona mas plana, por pasada. Las dos pasadas
// se componen, asi que el efecto total es mayor que este numero.
#define FUERZA 0.86

// Umbral de "estos dos vecinos son el mismo color, con la compresion de por
// medio". En unidades de luma (0..1): 0,09 son ~23 niveles de 255, el tamaño
// tipico de un escalon de macrobloque a bitrate corto.
#define SIGMA 0.09

// Caida del peso por distancia, en pixeles. 4,0 deja que la toma de +-8 pese
// todavia 0,14: poco, pero lo justo para arrastrar el valor del bloque vecino
// y aplanar el escalon.
#define SIGMA_ESPACIAL 4.0

// Donde empieza y acaba de apagarse la pasada por amplitud del salto.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

// Cuantos cambios de sentido hacen falta para dar el vecindario por textura.
// Por debajo de OSC_BAJA es un escalon o un degradado y el filtro entra
// entero; por encima de OSC_ALTA es grano y no se toca.
#define OSC_BAJA 1.0
#define OSC_ALTA 2.5

// Diferencia minima para que cuente como "sentido". ~1 nivel de 255: por
// debajo de eso es ruido de cuantizacion y contarlo como textura apagaria el
// filtro justo en las zonas planas que hay que arreglar.
#define MINIMO 0.004

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
    float d1 = m1 - m2;
    float d2 = centro - m1;
    float d3 = p1 - centro;
    float d4 = p2 - p1;
    float s1 = abs(d1) > MINIMO ? sign(d1) : 0.0;
    float s2 = abs(d2) > MINIMO ? sign(d2) : 0.0;
    float s3 = abs(d3) > MINIMO ? sign(d3) : 0.0;
    float s4 = abs(d4) > MINIMO ? sign(d4) : 0.0;
    float oscilacion = 0.0;
    oscilacion += (s1 * s2 < 0.0) ? 1.0 : 0.0;
    oscilacion += (s2 * s3 < 0.0) ? 1.0 : 0.0;
    oscilacion += (s3 * s4 < 0.0) ? 1.0 : 0.0;

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
    float textura = smoothstep(OSC_BAJA, OSC_ALTA, oscilacion);

    return vec4(
        mix(centro, promedio, planitud * (1.0 - textura) * FUERZA),
        0.0, 0.0, 1.0
    );
}

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 2/2 - vertical

// Los mismos valores que la pasada horizontal. Si se cambia uno hay que
// cambiar los dos: son las dos mitades del MISMO filtro, y descuadrarlos deja
// un desbloqueo mas fuerte en un eje que en el otro, que se ve como estrias.
#define FUERZA 0.86
#define SIGMA 0.09
#define SIGMA_ESPACIAL 4.0
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32
#define OSC_BAJA 1.0
#define OSC_ALTA 2.5
#define MINIMO 0.004

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

    float d1 = m1 - m2;
    float d2 = centro - m1;
    float d3 = p1 - centro;
    float d4 = p2 - p1;
    float s1 = abs(d1) > MINIMO ? sign(d1) : 0.0;
    float s2 = abs(d2) > MINIMO ? sign(d2) : 0.0;
    float s3 = abs(d3) > MINIMO ? sign(d3) : 0.0;
    float s4 = abs(d4) > MINIMO ? sign(d4) : 0.0;
    float oscilacion = 0.0;
    oscilacion += (s1 * s2 < 0.0) ? 1.0 : 0.0;
    oscilacion += (s2 * s3 < 0.0) ? 1.0 : 0.0;
    oscilacion += (s3 * s4 < 0.0) ? 1.0 : 0.0;

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
    float textura = smoothstep(OSC_BAJA, OSC_ALTA, oscilacion);

    return vec4(
        mix(centro, promedio, planitud * (1.0 - textura) * FUERZA),
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
#define NITIDEZ 0.45

// Tope del realce, en unidades de luma. Un detalle mas grande que esto ya es
// un borde de verdad y no necesita ayuda; dejarlo suelto es lo que produce
// los halos blancos junto a los contornos.
#define TOPE_DETALLE 0.06

// Cuanto grano. 0,006 son ~1,5 niveles de 255: por debajo del umbral de
// "esto tiene ruido" y por encima del de "esto esta muerto". Pedia un
// poquitito; esto es un poquitito.
#define GRANO 0.006

// Las mismas de las pasadas 1 y 2, para decidir que es plano y que textura.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32
#define OSC_BAJA 1.0
#define OSC_ALTA 2.5
#define MINIMO 0.004

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
    float hx1 = iz1 - iz2;
    float hx2 = centro - iz1;
    float hx3 = de1 - centro;
    float hx4 = de2 - de1;
    float oscH = 0.0;
    oscH += (sign(abs(hx1) > MINIMO ? hx1 : 0.0) *
             sign(abs(hx2) > MINIMO ? hx2 : 0.0) < 0.0) ? 1.0 : 0.0;
    oscH += (sign(abs(hx2) > MINIMO ? hx2 : 0.0) *
             sign(abs(hx3) > MINIMO ? hx3 : 0.0) < 0.0) ? 1.0 : 0.0;
    oscH += (sign(abs(hx3) > MINIMO ? hx3 : 0.0) *
             sign(abs(hx4) > MINIMO ? hx4 : 0.0) < 0.0) ? 1.0 : 0.0;

    float vy1 = ar1 - ar2;
    float vy2 = centro - ar1;
    float vy3 = ab1 - centro;
    float vy4 = ab2 - ab1;
    float oscV = 0.0;
    oscV += (sign(abs(vy1) > MINIMO ? vy1 : 0.0) *
             sign(abs(vy2) > MINIMO ? vy2 : 0.0) < 0.0) ? 1.0 : 0.0;
    oscV += (sign(abs(vy2) > MINIMO ? vy2 : 0.0) *
             sign(abs(vy3) > MINIMO ? vy3 : 0.0) < 0.0) ? 1.0 : 0.0;
    oscV += (sign(abs(vy3) > MINIMO ? vy3 : 0.0) *
             sign(abs(vy4) > MINIMO ? vy4 : 0.0) < 0.0) ? 1.0 : 0.0;

    float textura = smoothstep(OSC_BAJA, OSC_ALTA, max(oscH, oscV));

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
    float minimoLocal = min(min(iz1, de1), min(min(ar1, ab1), centro));
    float maximoLocal = max(max(iz1, de1), max(max(ar1, ab1), centro));
    realzado = clamp(realzado, minimoLocal, maximoLocal);

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
