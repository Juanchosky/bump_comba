// DESBLOQUEO LIGERO — UNA SOLA PASADA
//
// PARA QUE EXISTE
//
// El desbloqueo normal (`desbloqueo.glsl`) son TRES pasadas y unas 30 tomas
// por pixel. En el telefono va bien. En el televisor se probo el 2026-09-21 y
// la reproduccion se puso "super lenta, nada fluida" — pero se probo la copia
// del fotograma (`mediacodec-copy`) Y las tres pasadas A LA VEZ, asi que no
// se sabe cual de las dos costaba.
//
// Este archivo existe para separar esas dos cosas. Si con una sola pasada el
// televisor va fluido, el problema eran las pasadas y aqui hay desbloqueo de
// verdad; si sigue yendo mal, el problema es la copia y no hay nada que hacer
// por software en ese aparato.
//
// COMO SE PASA DE TRES PASADAS A UNA
//
// La clave es algo que ya sabiamos y que aqui se aprovecha entero: **solo hay
// que filtrar junto a la rejilla de macrobloques**. Y una frontera de rejilla
// es, o vertical, u horizontal. Casi ningun pixel esta cerca de las dos a la
// vez —solo las esquinas del bloque— asi que no hace falta filtrar en los dos
// ejes: basta con mirar cual de las dos fronteras cae mas cerca y filtrar
// PERPENDICULAR a ella, que es la unica direccion que cruza ese escalon.
//
// De 30 tomas por pixel a 11. Y las que quedan hacen el mismo trabajo donde
// de verdad importa.
//
// LO QUE SE PIERDE RESPECTO AL COMPLETO
//
// Honestamente: en las esquinas de bloque, donde se juntan una frontera
// vertical y una horizontal, esto arregla solo una de las dos. Son el 6% de
// los pixeles de la rejilla. Y no lleva la tercera pasada del completo —ni
// realce ni grano—, asi que el resultado es algo mas plano.
//
// A cambio cuesta un tercio.

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo ligero - una pasada, eje segun la rejilla

// Cuanto del promedio entra donde la compuerta abre del todo. Mas alto que en
// el completo (0,70) porque aqui NO hay una segunda pasada que componga
// encima: lo que haga esta, es todo lo que se hace.
#define FUERZA 0.85

// Umbral de "estos dos vecinos son el mismo color, con la compresion de por
// medio". 0,09 son ~23 niveles de 255, el tamaño tipico de un escalon de
// macrobloque a bitrate corto.
#define SIGMA 0.09

// Caida del peso por distancia, en pixeles.
#define SIGMA_ESPACIAL 3.0

// Donde empieza y acaba de apagarse por amplitud del salto.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

// Cuanta de la variacion local tiene que ir en una sola direccion para dar el
// vecindario por estructura (escalon o degradado) y filtrarlo. Por debajo de
// MONO_BAJA es textura y no se toca.
#define MONO_BAJA 0.35
#define MONO_ALTA 0.75

// Variacion por debajo de la cual el vecindario se da por plano del todo.
#define PLANO_TOTAL 0.002

// La rejilla del codificador y cuanto se filtra fuera de ella.
#define REJA 16.0
#define ANCHO_REJA 2.5
#define SUELO_FUERA 0.05

// Cuanto filtrar segun lo cerca que caiga `c` de una frontera de macrobloque.
float enLaReja(float c) {
    float dentro = mod(c, REJA);
    float distancia = min(dentro, REJA - dentro);
    float cerca = 1.0 - smoothstep(ANCHO_REJA, ANCHO_REJA + 2.0, distancia);
    return SUELO_FUERA + (1.0 - SUELO_FUERA) * cerca;
}

// A que distancia esta la frontera de rejilla mas cercana en esta coordenada.
float distanciaAReja(float c) {
    float dentro = mod(c, REJA);
    return min(dentro, REJA - dentro);
}

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    vec2 pixel = HOOKED_pos * HOOKED_size;

    // ── EL EJE ──────────────────────────────────────────────────────────
    // Se filtra PERPENDICULAR a la frontera mas cercana, que es la unica
    // direccion que la cruza. Junto a una frontera vertical hay que promediar
    // en horizontal; filtrar en vertical ahi no tocaria el escalon y solo
    // emborronaria.
    float distX = distanciaAReja(pixel.x);
    float distY = distanciaAReja(pixel.y);
    bool horizontal = distX <= distY;
    vec2 eje = horizontal ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
    float reja = enLaReja(horizontal ? pixel.x : pixel.y);

    // ── Y AQUI EL DETALLE QUE SE ME PASO LA PRIMERA VEZ ──────────────────
    //
    // Elegir el eje con un corte duro (`distX <= distY`) esta bien en el
    // interior del bloque, donde el filtro casi no actua. El problema son las
    // ESQUINAS: alli `distX` y `distY` valen las dos casi cero, el filtro
    // entra fuerte, y el eje cambia de golpe entre pixeles vecinos. Eso
    // siembra una costura en cada esquina de una retícula de 16 px — un
    // patron regular por toda la imagen, que se ve como suciedad.
    //
    // La salida es apagar el filtro justo donde la eleccion es dudosa. Si una
    // frontera esta claramente mas cerca que la otra, se filtra entero; si
    // estan empatadas, no se toca. Se pierde correccion en las esquinas —el
    // 6% de los pixeles de la rejilla— y a cambio no se inventa un patron
    // nuevo, que siempre se ve peor que el que se queria quitar.
    float dominancia = smoothstep(0.0, 2.0, abs(distX - distY));
    reja *= dominancia;

    // ── EL RACIMO CERCANO ───────────────────────────────────────────────
    float m2 = HOOKED_texOff(eje * -2.0).x;
    float m1 = HOOKED_texOff(eje * -1.0).x;
    float p1 = HOOKED_texOff(eje * 1.0).x;
    float p2 = HOOKED_texOff(eje * 2.0).x;

    float mayorSaltoCerca = max(abs(m1 - centro), abs(p1 - centro));

    // Monotonia: cuanta de la variacion va en una sola direccion. Es un
    // cociente, asi que no depende de la amplitud — funciona igual con un
    // escalon de 23 niveles que con poros de 2.
    float d1 = m1 - m2;
    float d2 = centro - m1;
    float d3 = p1 - centro;
    float d4 = p2 - p1;
    float variacion = abs(d1) + abs(d2) + abs(d3) + abs(d4);
    float neta = abs(d1 + d2 + d3 + d4);
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

    // Y el resto del alcance: +-4, +-6, +-8. Los desplazamientos se CALCULAN
    // y no se leen de un array: el constructor de arrays necesita GLSL ES 3.0
    // y hay aparatos con version mas vieja donde no compilaria.
    for (int k = 2; k <= 4; k++) {
        float d = float(k) * 2.0;
        float espacial = exp(-(d * d) /
                             (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
        float a = HOOKED_texOff(eje * -d).x;
        float b = HOOKED_texOff(eje * d).x;
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

    return vec4(
        mix(centro, promedio, planitud * estructura * reja * FUERZA),
        0.0, 0.0, 1.0
    );
}
