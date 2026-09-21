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
// La version anterior muestreaba en {-3,-1,0,+1,+3}: alcanzaba 3 pixeles por
// lado. Contra una reja de 16 px eso le lima el FILO al escalon pero no lo
// quita — para aplanar la frontera entre dos bloques planos hace falta llegar
// a la mitad del bloque, unos 8 pixeles.
//
// Un vecindario 2D de +-8 son 17x17 = 289 tomas por pixel. Inviable.
//
// La salida es separar el filtro en dos pasadas de una dimension: primero
// horizontal, luego vertical. Cada una toma 11 muestras, asi que son 22 en
// total y cubren un vecindario efectivo de 17x17. Menos coste que las 25
// tomas de la version anterior, con casi el triple de alcance.
//
// Un bilateral no es separable en sentido estricto —el peso de rango rompe la
// separabilidad— pero la aproximacion separable es la practica habitual en
// tiempo real y visualmente se comporta igual. Lo que se gana en alcance no
// tiene comparacion con lo que se pierde en exactitud.
//
// COMO DISTINGUE UN ARTEFACTO DE UN BORDE
//
// Dos mecanismos, y los dos hacen falta:
//
//   1. `rango` pesa cada vecino por lo PARECIDO que es al pixel central. Esto
//      es lo que protege a distancia: con un alcance de 8 px, muchas tomas
//      caen al otro lado de un borde, y el peso de rango las anula. Sin esto,
//      una reja tan ancha convertiria cada borde en una mancha.
//   2. `planitud` mira el salto del vecindario INMEDIATO (+-1 px) y apaga la
//      pasada entera donde hay estructura.
//
// Y en un filtro separable la compuerta cae de maravilla: la pasada
// horizontal mide el salto en horizontal, asi que un borde VERTICAL la apaga
// —que es justo lo que se quiere— y deja pasar la vertical, que en ese borde
// no tiene nada que estropear.
//
// POR QUE ENGANCHA EN `LUMA` Y NO EN `MAIN`
//
// Dos razones. En LUMA el fotograma esta todavia en su tamaño original —720p
// o menos— asi que la reja de macrobloques esta donde de verdad esta, sin
// estirar, y el filtro trabaja sobre el problema y no sobre su version
// escalada. Y son 921.600 pixeles en vez de los 2.073.600 de la salida a
// 1080p: menos de la mitad de trabajo.
//
// Solo luma porque ahi es donde se ve el damero. El croma de estas fuentes
// esta a un cuarto de resolucion y lo que tiene son manchas de color, no
// cuadrados.
//
// EL PRECIO, dicho claro: las dos pasadas se COMPONEN, asi que con `FUERZA`
// en 0,92 el efecto total es mas fuerte que el de la version de una pasada.
// El grano de pelicula y las texturas muy finas (tela, poros) se suavizan.
// Si queda de plastico, bajar `FUERZA` es lo primero y 0,80 es un buen primer
// escalon; NO tocar los umbrales de borde para eso.

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 1/2 - horizontal

// Cuanto del promedio entra en la zona mas plana, por pasada.
#define FUERZA 0.92

// El umbral de "estos dos vecinos son el mismo color, con la compresion de
// por medio". En unidades de luma (0..1): 0,09 son ~23 niveles de 255, el
// tamaño tipico de un escalon de macrobloque a bitrate corto.
#define SIGMA 0.09

// Caida del peso por distancia, en pixeles. 4,0 deja que la toma de +-8 pese
// todavia 0,14: poco, pero lo suficiente para arrastrar el valor del bloque
// vecino y aplanar el escalon. Con un valor menor, las tomas lejanas no
// pintarian nada y las dos pasadas no servirian de nada.
#define SIGMA_ESPACIAL 4.0

// Donde empieza y donde acaba de apagarse la pasada, mirando el salto del
// vecindario inmediato. 0,10 (~25 niveles) deja el filtro entero puesto en
// todo el rango del bloqueo; 0,32 (~82 niveles) es ya un borde real.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    float acumulado = centro;
    float pesos = 1.0;

    // La compuerta se mide SOLO en los vecinos inmediatos, y en el eje de
    // esta pasada. Medirla en todo el alcance de 8 px apagaria el filtro en
    // cualquier zona lisa que tenga un borde a media docena de pixeles — y
    // las cercanias de los bordes son justo donde la compresion deja mas
    // basura.
    float mayorSaltoCerca = 0.0;

    float izq = HOOKED_texOff(vec2(-1.0, 0.0)).x;
    float der = HOOKED_texOff(vec2(1.0, 0.0)).x;
    mayorSaltoCerca = max(abs(izq - centro), abs(der - centro));

    // Los dos vecinos de radio 1 ya estan leidos: se aprovechan.
    {
        float w = exp(-1.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
        float wi = w * exp(-((izq - centro) * (izq - centro)) /
                           (2.0 * SIGMA * SIGMA));
        float wd = w * exp(-((der - centro) * (der - centro)) /
                           (2.0 * SIGMA * SIGMA));
        acumulado += izq * wi + der * wd;
        pesos += wi + wd;
    }

    // Y el resto del alcance, de 2 en 2 hasta +-8.
    //
    // Los desplazamientos se CALCULAN, no se leen de un array: el
    // constructor de arrays necesita GLSL ES 3.0 y MPV tiene mensajes del
    // tipo "Disabling debanding (GLSL version too old)", o sea que hay
    // aparatos con version mas vieja donde el shader no compilaria entero.
    for (int k = 1; k <= 4; k++) {
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

    return vec4(mix(centro, promedio, planitud * FUERZA), 0.0, 0.0, 1.0);
}

//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo 2/2 - vertical

// Los mismos valores que la pasada horizontal. Si se cambia uno hay que
// cambiar los dos: son las dos mitades del MISMO filtro, y descuadrarlos deja
// un desbloqueo mas fuerte en un eje que en el otro, que se ve como estrias.
#define FUERZA 0.92
#define SIGMA 0.09
#define SIGMA_ESPACIAL 4.0
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

vec4 hook() {
    // OJO: `HOOKED` aqui ES LA SALIDA DE LA PASADA ANTERIOR.
    //
    // MPV encadena los hooks del mismo punto en el orden del archivo, asi que
    // esta pasada trabaja sobre la imagen ya desbloqueada en horizontal. De
    // ahi sale el vecindario efectivo de 17x17 con solo 22 tomas.
    float centro = HOOKED_tex(HOOKED_pos).x;

    float acumulado = centro;
    float pesos = 1.0;

    float mayorSaltoCerca = 0.0;

    float arr = HOOKED_texOff(vec2(0.0, -1.0)).x;
    float aba = HOOKED_texOff(vec2(0.0, 1.0)).x;
    mayorSaltoCerca = max(abs(arr - centro), abs(aba - centro));

    {
        float w = exp(-1.0 / (2.0 * SIGMA_ESPACIAL * SIGMA_ESPACIAL));
        float wa = w * exp(-((arr - centro) * (arr - centro)) /
                           (2.0 * SIGMA * SIGMA));
        float wb = w * exp(-((aba - centro) * (aba - centro)) /
                           (2.0 * SIGMA * SIGMA));
        acumulado += arr * wa + aba * wb;
        pesos += wa + wb;
    }

    for (int k = 1; k <= 4; k++) {
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

    return vec4(mix(centro, promedio, planitud * FUERZA), 0.0, 0.0, 1.0);
}
