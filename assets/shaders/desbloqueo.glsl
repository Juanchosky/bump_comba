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
//   · Un escalon PEQUEÑO entre vecinos en una zona lisa -> es el artefacto.
//     Se promedia y desaparece.
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
//   2. `planitud` mira el mayor salto del vecindario y apaga el filtro entero
//      donde hay estructura. En un borde nitido el filtro no hace NADA.
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

// Cuanto del promedio se deja entrar en la zona mas plana. A 1.0 el damero se
// va del todo pero las texturas finas —grano, tela, pelo— empiezan a perder
// cuerpo. 0.85 se come el artefacto dejando algo de la textura original.
#define FUERZA 0.85

// El umbral de "estos dos vecinos son el mismo color". En unidades de luma
// (0..1), asi que 0.028 son unos 7 niveles de 255: por debajo de eso ningun ojo
// ve una transicion legitima, es compresion.
#define SIGMA 0.028

// Donde empieza y donde acaba de apagarse el filtro. Entre estos dos valores se
// va yendo poco a poco: un corte seco se notaria como un halo alrededor de cada
// borde.
#define BORDE_BAJO 0.045
#define BORDE_ALTO 0.130

vec4 hook() {
    float centro = HOOKED_tex(HOOKED_pos).x;

    float acumulado = 0.0;
    float pesos = 0.0;
    float mayorSalto = 0.0;

    // 3x3 y no 5x5 a proposito: 9 muestras por pixel a 720p son ~8 millones de
    // lecturas por fotograma, que un movil de gama media traga sin enterarse.
    // Con 5x5 serian 23 millones, y este filtro ya va por el camino de
    // `mediacodec-copy`, que no es gratis.
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float vecino = HOOKED_texOff(vec2(float(x), float(y))).x;
            float salto = abs(vecino - centro);
            mayorSalto = max(mayorSalto, salto);

            // Peso por distancia: las esquinas del 3x3 estan mas lejos y
            // cuentan menos.
            float espacial = (x == 0 && y == 0)
                ? 1.0
                : ((x == 0 || y == 0) ? 0.6 : 0.35);

            // Peso por parecido. Esto es lo que impide que el promedio cruce
            // un borde.
            float rango = exp(-(salto * salto) / (2.0 * SIGMA * SIGMA));

            float peso = espacial * rango;
            acumulado += vecino * peso;
            pesos += peso;
        }
    }

    float promedio = acumulado / max(pesos, 1e-6);

    // 1.0 en zona lisa (aplicar), 0.0 sobre un borde (no tocar).
    float planitud = 1.0 - smoothstep(BORDE_BAJO, BORDE_ALTO, mayorSalto);

    return vec4(mix(centro, promedio, planitud * FUERZA), 0.0, 0.0, 1.0);
}
