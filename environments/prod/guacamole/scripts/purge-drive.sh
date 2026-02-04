#!/bin/bash
# =============================================================================
# PURGE DES DOSSIERS DRIVE GUACAMOLE
# =============================================================================
# Supprime le contenu des dossiers utilisateurs dans /data/guacamole/drive/
# Conserve les dossiers utilisateurs mais vide leur contenu
#
# Usage:
#   ./purge-drive.sh           - Purge avec confirmation
#   ./purge-drive.sh --yes     - Purge sans confirmation (pour cron)
#   ./purge-drive.sh --dry-run - Simulation sans suppression
#
# Installation cron (tous les jours à 16h):
#   echo "0 16 * * * /path/to/purge-drive.sh --yes >> /var/log/guacamole-purge.log 2>&1" | crontab -
# =============================================================================

set -e

DRIVE_PATH="/data/guacamole/drive"
LOG_FILE="/var/log/guacamole-purge.log"
DRY_RUN=false
AUTO_YES=false

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Parse arguments
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --yes|-y)
            AUTO_YES=true
            ;;
        --help|-h)
            echo "Usage: $0 [--yes] [--dry-run]"
            echo "  --yes, -y   : Pas de confirmation (pour cron)"
            echo "  --dry-run   : Simulation sans suppression"
            exit 0
            ;;
    esac
done

# Vérifier que le dossier existe
if [ ! -d "$DRIVE_PATH" ]; then
    log "ERREUR: $DRIVE_PATH n'existe pas"
    exit 1
fi

# Lister les dossiers utilisateurs
USER_DIRS=$(find "$DRIVE_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

if [ -z "$USER_DIRS" ]; then
    log "Aucun dossier utilisateur à purger dans $DRIVE_PATH"
    exit 0
fi

# Calculer la taille totale
TOTAL_SIZE=$(du -sh "$DRIVE_PATH" 2>/dev/null | cut -f1)
FILE_COUNT=$(find "$DRIVE_PATH" -mindepth 2 -type f 2>/dev/null | wc -l)

log "=== PURGE DRIVE GUACAMOLE ==="
log "Chemin: $DRIVE_PATH"
log "Taille totale: $TOTAL_SIZE"
log "Fichiers à supprimer: $FILE_COUNT"
log "Dossiers utilisateurs:"

for dir in $USER_DIRS; do
    USERNAME=$(basename "$dir")
    DIR_SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
    DIR_FILES=$(find "$dir" -type f 2>/dev/null | wc -l)
    log "  - $USERNAME: $DIR_SIZE ($DIR_FILES fichiers)"
done

if [ "$DRY_RUN" = true ]; then
    log "MODE DRY-RUN: Aucune suppression effectuée"
    exit 0
fi

# Confirmation si pas --yes
if [ "$AUTO_YES" != true ]; then
    echo ""
    read -p "Confirmer la purge de tous les fichiers ? [y/N] " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log "Purge annulée"
        exit 0
    fi
fi

# Effectuer la purge
log "Purge en cours..."
ERRORS=0

for dir in $USER_DIRS; do
    USERNAME=$(basename "$dir")
    if [ -d "$dir" ]; then
        # Supprimer le contenu mais garder le dossier
        if find "$dir" -mindepth 1 -delete 2>/dev/null; then
            log "  ✓ $USERNAME purgé"
        else
            log "  ✗ $USERNAME erreur de purge"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done

# Résumé
NEW_SIZE=$(du -sh "$DRIVE_PATH" 2>/dev/null | cut -f1)
log "=== PURGE TERMINÉE ==="
log "Espace libéré: $TOTAL_SIZE -> $NEW_SIZE"

if [ $ERRORS -gt 0 ]; then
    log "ATTENTION: $ERRORS erreurs rencontrées"
    exit 1
fi

exit 0
