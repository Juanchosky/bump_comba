//!HOOK LUMA
//!BIND HOOKED
//!DESC desbloqueo adaptativo para fuentes de bitrate corto

// QUE ARREGLA ESTO
//
// Los "pixelitos" de estas fuentes son macrobloques: el codificador del
// proveedor troceo la imagen en cuadrados, y con poco bitrate cada cuadrado se
// queda con un valor casi plano. El resultado es un damero visible, y se ve
// SOBRE TODO en las zonas lisas —cielos, paredes, pieles, fundidos— porque ahi
// no hay detalle que lo tape.
//
// Esa informacion esta destruida y no se puede recuperar. Lo que si se puede es
// que el damero deje de verse, y para eso hay que distinguir dos cosas que un
// desenfoque normal confunde:
//
//   · Un escalon en una zona lisa -> es el artefacto. Se promedia y desaparece.
//   · Un escalon GRANDE -> es un borde de verdad, el filo de una cara, una
//     letra. No se toca, porque suavizarlo es justo lo que hace que un video
//     filtrado parezca de plastico.
//
// COMO LO DISTINGUE
//
// Es un filtro bilateral con una compuerta de planitud:
//
//   1. `wr` pesa cada vecino por lo PARECIDO que es al pixel central. Un
//      vecino al otro lado de un borde pesa casi cero, asi que el promedio
//      nunca cruza un borde.
//   2. `planitud` mira el salto del vecindario INMEDIATO y apaga el filtro
//      entero donde hay estructura. En un borde nitido no hace NADA.
//
// POR QUE ENGANCHA EN `LUMA` Y NO EN `MAIN`
//
// Dos razones. La primera, que en LUMA el fotograma esta todavia en su tamaño
// original —720p o menos— asi que la reja de macrobloques esta donde de verdad
// esta, sin estirar, y el filtro trabaja sobre el problema y no sobre su
// version escalada. La segunda, que son 921.600 pixeles en vez de los 2.073.600
// de la salida a 1080p: menos de la mitad de trabajo para la GPU.
//
// Y solo luma porque ahi es donde se ve el damero. El croma de estas fuentes
// esta a un cuarto de resolucion y lo que tiene son manchas de color, no
// cuadrados; tocarlo costaria otra pasada para una mejora que no se nota.
//
// ── SEGUNDA VERSION: POR QUE LA PRIMERA NO BASTABA ─────────────────────────
//
// Probada en un telefono, la respuesta fue "aun se ven los cuadrados". Al
// mirar los numeros habia TRES cosas mal, y la peor no era la fuerza:
//
// 1. LA COMPUERTA APAGABA EL FILTRO DONDE MAS SE NECESITA. Estaba en
//    0,045-0,130 de luma, o sea 11-33 niveles de 255. Un escalon de
//    macrobloque de 30 niveles caia casi al final de esa rampa y dejaba
//    `planitud` en 0,06: el filtro practicamente desactivado justo en los
//    bloques mas gordos. Los umbrales de ahora (0,10-0,32) dejan pasar el
//    rango donde vive el bloqueo y solo se cierran ante un borde de verdad,
//    que son 80 niveles para arriba.
//
// 2. EL PESO DE RANGO TAMPOCO DEJABA PROMEDIAR. Con `SIGMA` en 0,028, un
//    vecino al otro lado de un escalon de 30 niveles pesaba 0,11 — se miraba
//    y se tiraba. Ahora pesa ~0,45 y el promedio puede hacer su trabajo.
//
// 3. EL VECINDARIO ERA DEMASIADO CORTO. Un macrobloque son 16x16 pixeles y un
//    3x3 solo alcanza UN pixel a cada lado de la frontera: se le limaba el
//    filo al escalon, pero el escalon seguia ahi. Ahora se muestrea en
//    {-3,-1,0,+1,+3}, que llega a 3 pixeles por lado y convierte el escalon en
//    una rampa de 6 pixeles, que es mucho menos visible.
//
// EL PRECIO, dicho claro: con estos valores el grano de pelicula y las
// texturas MUY finas (tela, poros) se suavizan algo. Es el intercambio que se
// pidio. Para volver atras, bajar `FUERZA` es lo primero; para ir mas lejos,
// subir `BORDE_ALTO`.

// Cuanto del promedio se deja entrar en la zona mas plana.
#define FUERZA 0.92

// El umbral de "estos dos vecinos son el mismo color, con la compresion de por
// medio". En unidades de luma (0..1): 0,09 son ~23 niveles de 255, que es el
// tamaño tipico de un escalon de macrobloque a bitrate corto.
#define SIGMA 0.09

// Donde empieza y donde acaba de apagarse el filtro, mirando el salto del
// vecindario inmediato. Entre los dos se va yendo poco a poco: un corte seco
// se notaria como un halo alrededor de cada borde.
//
// 0,10 (~25 niveles) deja el filtro entero puesto en todo el rango del
// bloqueo; 0,32 (~82 niveles) es ya un borde real y ahi no se toca nada.
#define BORDE_BAJO 0.10
#define BORDE_ALTO 0.32

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    float acumulado = 0.0;
    float pesos = 0.0;

    // El salto que decide la compuerta se mide SOLO en el anillo de radio 1.
    //
    // Si se midiera en todo el vecindario ancho, un borde a tres pixeles de
    // distancia apagaria el filtro en una zona lisa que si necesita arreglo —
    // y las cercanias de los bordes son justo donde la compresion deja mas
    // basura. Los bordes se detectan de cerca; el promedio se hace de lejos.
    float mayorSaltoCerca = 0.0;

    // Muestreo separado: {-3,-1,0,+1,+3}. 25 tomas que alcanzan 3 pixeles por
    // lado, el mismo coste que un 5x5 compacto pero con el doble de alcance,
    // que es lo que hace falta contra una reja de 16 pixeles. A 720p son ~23
    // millones de lecturas por fotograma; el aparato que llega hasta aqui ya
    // ha demostrado que va sobrado (ver el canario de FiltroCalidadService).
    //
    // Los desplazamientos se calculan, NO se leen de un array.
    //
    // Un `const float pasos[5] = float[5](...)` es lo natural aqui, pero el
    // constructor de arrays necesita GLSL ES 3.0, y MPV tiene mensajes del
    // tipo "Disabling debanding (GLSL version too old)": hay aparatos donde la
    // version es mas vieja. Ahi el shader no compilaria ENTERO, y por un
    // adorno. La cuenta `|k| > 1.5 ? k * 1.5 : k` da -3,-1,0,1,3 con puras
    // operaciones de siempre.
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            float fi = float(i);
            float fj = float(j);
            float dx = abs(fi) > 1.5 ? fi * 1.5 : fi;
            float dy = abs(fj) > 1.5 ? fj * 1.5 : fj;
            float vecino = HOOKED_texOff(vec2(dx, dy)).x;
            float salto = abs(vecino - centro);

            if (abs(dx) <= 1.0 && abs(dy) <= 1.0) {
                mayorSaltoCerca = max(mayorSaltoCerca, salto);
            }

            // Peso por distancia, en pixeles de verdad: las tomas de radio 3
            // cuentan bastante menos que las de radio 1, asi que el resultado
            // sigue pareciendose al original y no a una mancha.
            float d2 = dx * dx + dy * dy;
            float espacial = exp(-d2 / 8.0);

            // Peso por parecido. Esto es lo que impide que el promedio cruce
            // un borde aunque la compuerta lo haya dejado pasar.
            float rango = exp(-(salto * salto) / (2.0 * SIGMA * SIGMA));

            float peso = espacial * rango;
            acumulado += vecino * peso;
            pesos += peso;
        }
    }

    float promedio = acumulado / max(pesos, 1e-6);

    // 1.0 en zona lisa (aplicar), 0.0 sobre un borde (no tocar).
    float planitud = 1.0 - smoothstep(BORDE_BAJO, BORDE_ALTO, mayorSaltoCerca);

    return vec4(mix(centro, promedio, planitud * FUERZA), 0.0, 0.0, 1.0);
}
