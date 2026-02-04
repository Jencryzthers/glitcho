# Changelog - Glitcho

## Version 1.0.4

- Added live stream recording with Streamlink and in-player controls.
- Added Recording settings to choose the output folder and Streamlink binary path.

---

## Version 1.0.3

- Added pinned channels (pin/unpin) with per-channel notification toggles.
- Added Settings window and improved sidebar UX around channel management.
- Added in-app update checking (GitHub releases) with prompts and status messaging.
- Added detached chat window support and Picture-in-Picture groundwork for native playback.

---

## Version 1.0.2

- Bump version to **1.0.2** (bundle version now set by `Scripts/make_app.sh`).
- About window now reads the version from the app bundle, so it always stays in sync.
- Repo hygiene: stop tracking build outputs (`.build/`, `Build/`) and macOS metadata files.

---

## Version 3.0 - Enhanced Ad Blocking + Rename to Glitcho

### 🎉 Nouvelles fonctionnalités

#### 🚫 Système de blocage amélioré (inspiré d'uBlock Origin)
- **Blocage réseau** : 40+ domaines publicitaires et de tracking bloqués
  - Google Ads, Amazon Ads, Facebook Pixel, etc.
  - Patterns d'URL publicitaires détectés et bloqués
- **Filtrage CSS avancé** : 80+ sélecteurs pour masquer tous types d'éléments publicitaires
  - Éléments vidéo, bannières, overlays, contenu sponsorisé
  - Pixels de tracking et scripts analytics
- **Blocage M3U8** : Filtrage des segments publicitaires dans les playlists vidéo
- **Surveillance dynamique** : MutationObserver pour bloquer scripts/iframes en temps réel
- **Blocage des images** : Interception de Image.src pour les pixels de tracking

#### 🎨 Refonte complète de l'interface

**Section Logo & Header**
- Meilleur espacement et alignement
- Design plus épuré

**Section Profile/Account**
- Design modernisé avec conteneur distinct
- Avatar agrandi (40x40px) avec bordures dégradées
- Ombres subtiles pour plus de profondeur
- Nouveaux états de chargement et d'erreur
- Bouton "Log in" avec dégradé violet Twitch
- Bouton Settings repensé avec icône

**Barre de recherche**
- État focus interactif avec animations
- Bouton "×" pour effacer le texte
- Transitions fluides
- Meilleur contraste visuel
- Indicateur de focus

**Navigation (Explore/Following)**
- Effets hover animés sur tous les éléments
- Espacement optimisé
- Titres en majuscules avec tracking
- Icônes parfaitement alignées
- Background hover subtil

**Channels en direct**
- Badge "LIVE" avec point rouge animé
- Thumbnails circulaires au lieu de rectangulaires
- Meilleur contraste pour les noms
- Indicateur de statut live plus visible

**Typographie**
- Poids et tailles ajustés
- Hiérarchie visuelle améliorée
- Meilleure lisibilité

### 🛠️ Améliorations techniques

**WebViewStore.swift**
- Script `adBlockScript` amélioré avec règles uBlock Origin
- Blocage réseau des domaines publicitaires (fetch + XMLHttpRequest)
- Filtrage CSS étendu (80+ sélecteurs)
- MutationObserver pour bloquer dynamiquement les éléments
- Nettoyage agressif des éléments publicitaires toutes les secondes

**ContentView.swift**
- Correction des erreurs de type avec `foregroundStyle`
- Utilisation appropriée de `Color` vs styles hiérarchiques
- Suppression des références `scrollView` dans `PopupWebViewContainer`

### 📝 Documentation

**Mises à jour**
- `README.md` : Nouvelles fonctionnalités de blocage
- `QUICKSTART.md` : Guide mis à jour
- `INSTALL.md` : Instructions simplifiées
- `CHANGELOG.md` : Historique complet

### ⚠️ Notes importantes

1. **Blocage côté client** : Filtrage effectué dans l'application
2. **Efficacité variable** : Dépend des mises à jour de Twitch
3. **Multi-couches** : Plusieurs techniques combinées pour une meilleure efficacité

### 🎯 Comparaison avec navigateurs

| Fonctionnalité | Navigateur web | Twitch Glass App |
|---|---|---|
| Blocage de pubs | 🟡 Extension requise | ✅ Intégré |
| Interface épurée | ❌ Non | ✅ Oui |
| Design natif macOS | ❌ Non | ✅ Glass UI |
| Performances | 🟡 Moyenne | ✅ Optimisées |
| Blocage multi-couches | 🟡 Limité | ✅ Complet |

---

## Version 2.0 - UI Redesign

- Interface glass-morphic complète
- Sidebar personnalisée avec navigation fluide
- Section profil/account modernisée
- Badge "LIVE" avec animations
- Effets hover et transitions
- Blocage de publicités de base

---

## Version 1.0 - Release initiale

- Application macOS native avec WebView Twitch
- Interface de base
- Navigation personnalisée
- Suivi des chaînes suivies
