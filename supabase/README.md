# Base de datos de Vuelve (Supabase)

Proyecto: `vzzkzajzzehhxzwonpgv` · región eu-west-1 (Irlanda).

Las migraciones de `migrations/` ya están aplicadas, en orden. Para montar Vuelve en otro proyecto de Supabase,
ejecútalas en ese orden en el SQL Editor y pon la URL y la publishable key del nuevo proyecto en `index.html`
(`SUPABASE_URL` y `SUPABASE_KEY`).

Qué guarda cada tabla:

| Tabla | Contenido | Quién la ve |
| --- | --- | --- |
| `user_docs` | Perfil, diario por meses y mealprep de cada persona | Solo su dueña |
| `dia_resumen` | Por día: ¿cumplió calorías? ¿se movió? (sí/no) | Ella y sus compañeras de reto |
| `retos` | Nombre, tipo, fechas del reto | La dueña, participantes e invitadas |
| `reto_miembros` | Invitadas y participantes de cada reto | La dueña, participantes y la propia invitada |

Las funciones auxiliares de las reglas viven en el esquema `private`, que no se expone por la API.
