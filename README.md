## 🚀 À propos de GitShadow-Compose

Ce projet est né d'un constat simple : multiplier les GitHub Runners sur une même machine ne devrait pas multiplier la consommation de bande passante. 

**GitShadow-Compose** met en place une infrastructure "offline-first-ish" pour tes Actions GitHub :
*   **Sandboxing :** Chaque worker tourne dans son propre container isolé.
*   **Shadow Cache :** Un proxy Git transparent intercepte les requêtes. Il maintient une version `bare` à jour de tes repos et sert les données aux runners à la vitesse du réseau local.
*   **Performance :** Réduit drastiquement le temps d'exécution des étapes `actions/checkout`, particulièrement sur les gros projets .NET ou MAUI.