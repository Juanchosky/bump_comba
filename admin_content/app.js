// Configuración de Supabase
const SUPABASE_URL = 'https://inukqboqdvwtmmthjwrl.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImludWtxYm9xZHZ3dG1tdGhqd3JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzkyMzM3NDIsImV4cCI6MjA1NDgwOTc0Mn0.bWNkWIErT71tXchtxN9D83w-I--UIGOIzZKff3-X5V8';

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// ─────────────────────────────────────────────────────────────────────────────
// AUTH — Login / Logout usando tabla admin_users
// ─────────────────────────────────────────────────────────────────────────────

const SESSION_KEY = 'admin_session';

/** Hash SHA-256 de un string usando Web Crypto API (disponible en todos los browsers modernos) */
async function sha256(message) {
    const msgBuffer = new TextEncoder().encode(message);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

/** Guarda la sesión en sessionStorage (se borra al cerrar el tab) */
function saveSession(user) {
    sessionStorage.setItem(SESSION_KEY, JSON.stringify({ id: user.id, username: user.username, role: user.role }));
}

function getSession() {
    try { return JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch { return null; }
}

function clearSession() {
    sessionStorage.removeItem(SESSION_KEY);
}

/** Muestra el dashboard y oculta el login */
function showDashboard(user) {
    const loginScreen = document.getElementById('login-screen');
    const appContainer = document.querySelector('.app-container');

    // Actualizar sidebar con el nombre del usuario
    const avatarEl = document.getElementById('sidebar-avatar');
    const usernameEl = document.getElementById('sidebar-username');
    if (avatarEl) avatarEl.textContent = user.username.charAt(0).toUpperCase();
    if (usernameEl) usernameEl.textContent = user.username;

    loginScreen.classList.add('fade-out');
    appContainer.classList.remove('hidden');
}

/** Muestra el login y oculta el dashboard */
function showLogin() {
    const loginScreen = document.getElementById('login-screen');
    const appContainer = document.querySelector('.app-container');
    loginScreen.classList.remove('fade-out');
    appContainer.classList.add('hidden');
}

/** Intenta autenticar al usuario contra la tabla admin_users */
async function attemptLogin(username, password) {
    const hash = await sha256(password);

    const { data, error } = await supabaseClient
        .from('admin_users')
        .select('id, username, role')
        .eq('username', username)
        .eq('password_hash', hash)
        .single();

    if (error || !data) return null;

    // Actualizar last_login (no-blocking)
    supabaseClient
        .from('admin_users')
        .update({ last_login: new Date().toISOString() })
        .eq('id', data.id)
        .then(() => {});

    return data;
}

/** Configura los event listeners del formulario de login */
function setupLoginForm() {
    const form = document.getElementById('login-form');
    const loginBtn = document.getElementById('login-btn');
    const errorDiv = document.getElementById('login-error');
    const errorMsg = document.getElementById('login-error-msg');
    const toggleBtn = document.getElementById('toggle-password');
    const passwordInput = document.getElementById('login-password');
    const eyeIcon = document.getElementById('eye-icon');

    // Show/hide password toggle
    toggleBtn.addEventListener('click', () => {
        const isHidden = passwordInput.type === 'password';
        passwordInput.type = isHidden ? 'text' : 'password';
        eyeIcon.setAttribute('data-lucide', isHidden ? 'eye-off' : 'eye');
        lucide.createIcons();
    });

    form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const username = document.getElementById('login-username').value.trim();
        const password = document.getElementById('login-password').value;

        if (!username || !password) return;

        // Loading state
        loginBtn.disabled = true;
        loginBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Verificando...';
        lucide.createIcons();
        errorDiv.classList.add('hidden');

        try {
            const user = await attemptLogin(username, password);

            if (!user) {
                // Error de credenciales
                errorMsg.textContent = 'Usuario o contraseña incorrectos.';
                errorDiv.classList.remove('hidden');
                // Re-trigger animation
                errorDiv.style.animation = 'none';
                errorDiv.offsetHeight; // reflow
                errorDiv.style.animation = '';
                lucide.createIcons();
            } else {
                // ✅ Autenticado
                saveSession(user);
                showDashboard(user);
                // Inicializar el dashboard
                await fetchContent();
                setupEventListeners();
                lucide.createIcons();
            }
        } catch (err) {
            errorMsg.textContent = 'Error de conexión. Verifica tu red.';
            errorDiv.classList.remove('hidden');
            lucide.createIcons();
        } finally {
            loginBtn.disabled = false;
            loginBtn.innerHTML = '<i data-lucide="log-in"></i> Iniciar Sesión';
            lucide.createIcons();
        }
    });
}

/** Configura el botón de logout */
function setupLogout() {
    const logoutBtn = document.getElementById('logout-btn');
    if (logoutBtn) {
        logoutBtn.addEventListener('click', () => {
            clearSession();
            showLogin();
            // Limpiar estado del dashboard
            allContent = [];
            seriesList = [];
            episodeCountMap = {};
            currentTab = 'movies';
            activeSeriesFilter = null;
            if (document.getElementById('content-list-body')) {
                document.getElementById('content-list-body').innerHTML = '';
            }
        });
    }
}


// Estado Global
let allContent = [];
let seriesList = [];
let episodeCountMap = {}; // { [seriesId]: number } — conteo de episodios por serie
let currentTab = 'movies';
let activeSeriesFilter = null;
let viewMode = localStorage.getItem('viewMode') || 'list';


// Elementos DOM
const contentTableBody = document.getElementById('content-list-body');
const contentModal = document.getElementById('content-modal');
const contentForm = document.getElementById('content-form');
const addContentBtn = document.getElementById('add-content-btn');
const closeButtons = document.querySelectorAll('.close-modal');
const typeSelect = document.getElementById('type');
const seriesFields = document.getElementById('series-fields');
const parentIdSelect = document.getElementById('parent_id');
const searchInput = document.getElementById('global-search');
const filterCategory = document.getElementById('filter-category');
const filterSeason = document.getElementById('filter-season');
const seriesGrid = document.getElementById('series-grid');
const dataTableContainer = document.getElementById('data-table-container');
const tabButtons = document.querySelectorAll('.tab-btn');
const pageTitle = document.getElementById('page-title');
const backToSeriesBtn = document.getElementById('back-to-series');
const tableHeadRow = document.getElementById('table-head-row');
const viewListBtn = document.getElementById('view-list');
const viewGridBtn = document.getElementById('view-grid');
const manageSeasonsBtn = document.getElementById('manage-seasons-btn');
const bulkDeleteModal = document.getElementById('bulk-delete-modal');
const seasonsCheckboxList = document.getElementById('seasons-checkbox-list');
const confirmBulkDeleteBtn = document.getElementById('confirm-bulk-delete-btn');
const closeBulkDeleteBtns = document.querySelectorAll('.close-bulk-delete');
const autoImportBtn = document.getElementById('auto-import-btn');
const importModal = document.getElementById('import-modal');
const confirmImportBtn = document.getElementById('confirm-import-btn');
const importUrlInput = document.getElementById('import-url');
const toast = document.getElementById('toast');

const toastMessage = document.getElementById('toast-message');
const toastIcon = document.getElementById('toast-icon');
const closeImportModalBtns = document.querySelectorAll('.close-import-modal');



function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

// ─────────────────────────────────────────────────────────────────────────────
// BORRADO MASIVO DE TEMPORADAS
// ─────────────────────────────────────────────────────────────────────────────
function openBulkDeleteModal() {
    if (!activeSeriesFilter) return;
    
    const episodes = allContent.filter(item => item.type === 'episode' && item.parent_id === activeSeriesFilter);
    const seasons = [...new Set(episodes.map(it => it.season).filter(s => s !== null))].sort((a, b) => a - b);
    
    if (seasons.length === 0) {
        showToast('Esta serie no tiene temporadas para borrar', 'error');
        return;
    }

    seasonsCheckboxList.innerHTML = '';
    seasons.forEach(s => {
        const item = document.createElement('label');
        item.className = 'checkbox-container';
        item.style.display = 'flex';
        item.style.alignItems = 'center';
        item.style.gap = '0.5rem';
        item.style.cursor = 'pointer';
        item.innerHTML = `
            <input type="checkbox" value="${s}" class="season-checkbox">
            <span class="checkmark"></span>
            <span style="font-size:0.95rem;">Temporada ${s}</span>
        `;
        seasonsCheckboxList.appendChild(item);
    });

    bulkDeleteModal.style.display = 'block';
    lucide.createIcons();
}

async function confirmBulkDelete() {
    const checkedBoxes = document.querySelectorAll('.season-checkbox:checked');
    const selectedSeasons = Array.from(checkedBoxes).map(cb => parseInt(cb.value));

    if (selectedSeasons.length === 0) {
        showToast('Selecciona al menos una temporada', 'error');
        return;
    }

    const series = allContent.find(s => s.id === activeSeriesFilter);
    const seriesName = series ? series.title : 'esta serie';

    if (!confirm(`¿Borrar definitivamente las temporadas (${selectedSeasons.join(', ')}) de "${seriesName}"?\nSe eliminarán todos sus capítulos.`)) return;

    confirmBulkDeleteBtn.disabled = true;
    confirmBulkDeleteBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Borrando...';
    lucide.createIcons();

    try {
        const { error } = await supabaseClient
            .from('custom_content')
            .delete()
            .eq('type', 'episode')
            .eq('parent_id', activeSeriesFilter)
            .in('season', selectedSeasons);

        if (error) throw error;

        showToast(`Se han borrado ${selectedSeasons.length} temporadas`, 'success');
        bulkDeleteModal.style.display = 'none';

        // Recargar episodios y actualizar UI
        const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
        allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
        allContent = allContent.concat(episodes);

        // Actualizar conteo en el mapa
        episodeCountMap[activeSeriesFilter] = episodes.length;

        populateSeasonSelect(activeSeriesFilter);
        applyFilters();
    } catch (err) {
        showToast('Error: ' + err.message, 'error');
    } finally {
        confirmBulkDeleteBtn.disabled = false;
        confirmBulkDeleteBtn.innerHTML = 'Borrar Seleccionadas';
        lucide.createIcons();
    }
}



document.addEventListener('DOMContentLoaded', async () => {
    // Ocultar dashboard inicialmente
    document.querySelector('.app-container').classList.add('hidden');

    // Configurar logout y login form siempre
    setupLogout();
    setupLoginForm();
    lucide.createIcons();

    // Verificar si hay sesión activa (el usuario ya estaba logueado en este tab)
    const session = getSession();
    if (session) {
        // Sesión existente — ir directo al dashboard
        showDashboard(session);
        await fetchContent();
        setupEventListeners();
        lucide.createIcons();
    }
    // Si no hay sesión, el login-screen ya es visible por defecto
});

// Carga películas y series en paralelo + conteos de episodios por serie
async function fetchContent() {
    const [movResult, serResult] = await Promise.all([
        supabaseClient.from('custom_content').select('*').eq('type', 'movie').order('created_at', { ascending: false }),
        supabaseClient.from('custom_content').select('*').eq('type', 'series').order('created_at', { ascending: false }),
    ]);

    const movies  = movResult.data || [];
    const series  = serResult.data || [];
    allContent = [...movies, ...series];
    seriesList = series;

    // Obtener conteos de episodios en paralelo (solo HEAD — cero datos transferidos)
    const countResults = await Promise.all(
        series.map(s =>
            supabaseClient
                .from('custom_content')
                .select('*', { count: 'exact', head: true })
                .eq('type', 'episode')
                .eq('parent_id', s.id)
                .then(({ count }) => ({ id: s.id, count: count || 0 }))
        )
    );
    episodeCountMap = {};
    countResults.forEach(({ id, count }) => { episodeCountMap[id] = count; });

    populateSeriesSelect();
    applyFilters();
}


// Carga episodios de una serie específica (solo cuando el usuario entra a la serie)
async function fetchEpisodesForSeries(seriesId) {
    const { data, error } = await supabaseClient
        .from('custom_content')
        .select('*')
        .eq('type', 'episode')
        .eq('parent_id', seriesId)
        .order('season', { ascending: true })
        .order('episode', { ascending: true });
    if (error) { console.error('Error episodes:', error); return []; }
    return data || [];
}


function renderTableHead(viewType) {
    if (viewType === 'episodes') {
        tableHeadRow.innerHTML = `<th>Capítulo</th><th>Temporada</th><th>Episodio</th><th>Estado</th><th>Acciones</th>`;
    } else {
        tableHeadRow.innerHTML = `<th>Título</th><th>Categoría</th><th>Estado</th><th>Acciones</th>`;
    }
}

function renderContent(items) {
    viewListBtn.classList.toggle('active', viewMode === 'list');
    viewGridBtn.classList.toggle('active', viewMode === 'grid');
    if (viewMode === 'grid') { renderGridView(items); return; }
    seriesGrid.classList.add('hidden');
    dataTableContainer.classList.remove('hidden');
    contentTableBody.innerHTML = '';
    const isEpisodeView = currentTab === 'series' && activeSeriesFilter;
    renderTableHead(isEpisodeView ? 'episodes' : 'movies');
    items.forEach(item => {
        const tr = document.createElement('tr');
        tr.innerHTML = `
            <td>
                <div style="display:flex;align-items:center;gap:1rem;">
                    <img src="${item.thumbnail_url || 'https://via.placeholder.com/40x60'}" style="width:40px;height:60px;object-fit:cover;border-radius:4px;background:#000;">
                    <div>
                        <div style="font-weight:600;">${item.title}</div>
                        <div style="font-size:.75rem;color:var(--text-muted);">${item.id.slice(0, 8)}...</div>
                    </div>
                </div>
            </td>
            ${isEpisodeView ? `<td data-label="Temporada">S${item.season || '-'}</td><td data-label="Episodio">E${item.episode || '-'}</td>` : `<td data-label="Categoría">${item.category}</td>`}
            <td data-label="Estado">
                <label class="switch">
                    <input type="checkbox" ${item.is_active ? 'checked' : ''} onchange="toggleStatus('${item.id}', this.checked)">
                    <span class="slider"></span>
                </label>
            </td>
            <td data-label="Acciones">
                <div class="actions">
                    <button class="btn-icon btn-edit" onclick="editItem('${item.id}')"><i data-lucide="edit-3"></i></button>
                    <button class="btn-icon btn-delete" onclick="deleteItem('${item.id}')"><i data-lucide="trash-2"></i></button>
                </div>
            </td>
        `;
        contentTableBody.appendChild(tr);
    });
    lucide.createIcons();
}

function renderGridView(items) {
    seriesGrid.classList.remove('hidden');
    dataTableContainer.classList.add('hidden');
    seriesGrid.innerHTML = '';
    items.forEach(item => {
        const card = document.createElement('div');
        card.className = 'series-card';
        if (item.type === 'series') { card.onclick = () => enterSeries(item.id); } else { card.onclick = () => editItem(item.id); }
        // Usar el conteo pre-cargado (no requiere iterar allContent)
        const episodeCount = item.type === 'series' ? (episodeCountMap[item.id] ?? 0) : 0;

        card.innerHTML = `
            <div class="series-actions">
                <button class="btn-icon btn-edit" onclick="event.stopPropagation();editItem('${item.id}')"><i data-lucide="edit-3"></i></button>
                <button class="btn-icon btn-delete" onclick="event.stopPropagation();deleteItem('${item.id}')"><i data-lucide="trash-2"></i></button>
            </div>
            <img class="series-poster" src="${item.thumbnail_url || 'https://via.placeholder.com/220x330'}" alt="${item.title}">
            <div class="series-info">
                <div class="series-title">${item.title}</div>
                <div class="series-meta">
                    <span>${item.type === 'episode' ? `S${item.season} E${item.episode}` : item.category}</span>
                    ${item.type === 'series' ? `<span class="episode-count">${episodeCount} capítulos</span>` : ''}
                </div>
            </div>
        `;
        seriesGrid.appendChild(card);
    });
    lucide.createIcons();
}

function populateSeriesSelect() {
    parentIdSelect.innerHTML = '<option value="">Selecciona una serie...</option>';
    seriesList.sort((a, b) => a.title.localeCompare(b.title)).forEach(series => {
        const option = document.createElement('option');
        option.value = series.id;
        option.textContent = series.title;
        parentIdSelect.appendChild(option);
    });
}

async function enterSeries(id) {
    activeSeriesFilter = id;
    const series = allContent.find(s => s.id === id);
    pageTitle.textContent = `Capítulos de: ${series.title}`;
    backToSeriesBtn.classList.remove('hidden');
    filterCategory.classList.add('hidden');
    filterSeason.classList.remove('hidden');
    // manageSeasonsBtn siempre visible dentro de una serie
    manageSeasonsBtn.classList.remove('hidden');
    filterSeason.value = 'all';
    lucide.createIcons();



    // Cargar episodios desde la BD solo ahora que el usuario entró a la serie
    const episodes = await fetchEpisodesForSeries(id);
    // Añadir/reemplazar episodios en allContent sin borrar movies/series
    allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === id));
    allContent = allContent.concat(episodes);

    populateSeasonSelect(id);
    applyFilters();
}


function exitSeries() {
    activeSeriesFilter = null;
    pageTitle.textContent = 'Mis Series';
    backToSeriesBtn.classList.add('hidden');
    filterCategory.classList.remove('hidden');
    filterSeason.classList.add('hidden');
    manageSeasonsBtn.classList.add('hidden');
    if (!localStorage.getItem('viewMode')) viewMode = 'grid';

    applyFilters();
}


function populateSeasonSelect(seriesId) {
    const episodes = allContent.filter(item => item.type === 'episode' && item.parent_id === seriesId);
    const seasons = [...new Set(episodes.map(it => it.season).filter(s => s !== null))].sort((a, b) => a - b);
    filterSeason.innerHTML = '<option value="all">Todas las Temporadas</option>';
    seasons.forEach(season => {
        const option = document.createElement('option');
        option.value = season;
        option.textContent = `Temporada ${season}`;
        filterSeason.appendChild(option);
    });
}

/**
 * Limpia una URL de video de fragmentos de tiempo (#t=...) y parámetros comunes (?t=, &time=, etc.)
 */
function cleanVideoUrl(url) {
    if (!url || typeof url !== 'string') return url;
    try {
        // 1. Eliminar fragmentos (#t=...)
        let cleaned = url.split('#')[0];
        
        // 2. Usar URL API para limpiar parámetros de búsqueda específicos
        const urlObj = new URL(cleaned);
        const paramsToRemove = ['t', 'time', 'start', 'at', 'position'];
        paramsToRemove.forEach(p => urlObj.searchParams.delete(p));
        
        return urlObj.toString();
    } catch (e) {
        // Fallback robusto con regex si la URL es parcial o inválida para el constructor URL
        return url.replace(/[#&?](t|time|start|at|position)=\d+[smh]?/g, '');
    }
}

async function saveContent(e) {
    e.preventDefault();
    const id = document.getElementById('item-id').value;
    const rawVideoUrl = document.getElementById('video_url').value;
    const formData = {
        title: document.getElementById('title').value,
        type: document.getElementById('type').value,
        category: document.getElementById('category').value,
        video_url: cleanVideoUrl(rawVideoUrl) || null,
        thumbnail_url: document.getElementById('thumbnail_url').value || null,
        is_active: document.getElementById('is_active').checked,
        parent_id: document.getElementById('parent_id').value || null,
        season: parseInt(document.getElementById('season').value) || null,
        episode: parseInt(document.getElementById('episode').value) || null,
    };

    let result;
    if (id) { result = await supabaseClient.from('custom_content').update(formData).eq('id', id); }
    else { result = await supabaseClient.from('custom_content').insert([formData]); }
    if (result.error) { alert('Error al guardar: ' + result.error.message); return; }

    // ── Propagación de poster a episodios sin thumbnail ──────────────────────
    // Si es una serie con thumbnail, actualiza episodios que no tienen poster propio
    const seriesId = id; // la serie editada
    if (formData.type === 'series' && formData.thumbnail_url && seriesId) {
        const { data: updated, error: propErr } = await supabaseClient
            .from('custom_content')
            .update({ thumbnail_url: formData.thumbnail_url })
            .eq('type', 'episode')
            .eq('parent_id', seriesId)
            .or('thumbnail_url.is.null,thumbnail_url.eq.');
        if (!propErr) {
            showToast(`Poster actualizado en episodios sin imagen`, 'success');
        }
    }

    closeModal();
    // Si estamos en vista de episodios, recargar solo los episodios de esa serie
    if (activeSeriesFilter) {
        const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
        allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
        allContent = allContent.concat(episodes);
        populateSeasonSelect(activeSeriesFilter);
        applyFilters();
    } else {
        await fetchContent();
    }

}


async function toggleStatus(id, isActive) {
    const { error } = await supabaseClient.from('custom_content').update({ is_active: isActive }).eq('id', id);
    if (error) { alert('Error al cambiar estado: ' + error.message); fetchContent(); }
}

async function deleteItem(id) {
    if (confirm('¿Estás seguro de que deseas eliminar este contenido?')) {
        const { error } = await supabaseClient.from('custom_content').delete().eq('id', id);
        if (error) { alert('Error al eliminar: ' + error.message); return; }
        if (activeSeriesFilter) {
            const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
            allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
            allContent = allContent.concat(episodes);
            populateSeasonSelect(activeSeriesFilter);
            applyFilters();
        } else {
            await fetchContent();
        }
    }
}


function editItem(id) {
    const item = allContent.find(i => i.id === id);
    if (!item) return;
    document.getElementById('item-id').value = item.id;
    document.getElementById('title').value = item.title;
    document.getElementById('type').value = item.type;
    document.getElementById('category').value = item.category;
    document.getElementById('video_url').value = item.video_url || '';
    document.getElementById('thumbnail_url').value = item.thumbnail_url || '';
    document.getElementById('is_active').checked = item.is_active;
    document.getElementById('parent_id').value = item.parent_id || '';
    document.getElementById('season').value = item.season || '';
    document.getElementById('episode').value = item.episode || '';
    handleTypeChange();
    document.getElementById('modal-title').textContent = 'Editar Contenido';
    contentModal.style.display = 'block';
}

function setupEventListeners() {
    addContentBtn.onclick = () => {
        contentForm.reset();
        document.getElementById('item-id').value = '';
        document.getElementById('modal-title').textContent = 'Agregar Contenido';
        if (currentTab === 'series' && activeSeriesFilter) { typeSelect.value = 'episode'; parentIdSelect.value = activeSeriesFilter; }
        else if (currentTab === 'movies') { typeSelect.value = 'movie'; }
        else { typeSelect.value = 'series'; }
        handleTypeChange();
        contentModal.style.display = 'block';
    };

    closeButtons.forEach(btn => { btn.onclick = closeModal; });
    backToSeriesBtn.onclick = exitSeries;

    window.onclick = (event) => {
        if (event.target == contentModal) closeModal();
        if (event.target == importModal) importModal.style.display = 'none';
        if (event.target == bulkDeleteModal) bulkDeleteModal.style.display = 'none';
    };


    tabButtons.forEach(btn => {
        btn.onclick = () => {
            tabButtons.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentTab = btn.dataset.tab;
            activeSeriesFilter = null;
            backToSeriesBtn.classList.add('hidden');
            pageTitle.textContent = currentTab === 'movies' ? 'Mis Películas' : 'Mis Series';
            if (!localStorage.getItem('viewMode')) viewMode = currentTab === 'series' ? 'grid' : 'list';
            applyFilters();
        };
    });

    viewListBtn.onclick = () => { viewMode = 'list'; localStorage.setItem('viewMode', 'list'); applyFilters(); };
    viewGridBtn.onclick = () => { viewMode = 'grid'; localStorage.setItem('viewMode', 'grid'); applyFilters(); };
    typeSelect.onchange = handleTypeChange;
    contentForm.onsubmit = saveContent;
    searchInput.oninput = applyFilters;
    filterCategory.onchange = applyFilters;
    filterSeason.onchange = applyFilters;
    
    manageSeasonsBtn.onclick = openBulkDeleteModal;
    closeBulkDeleteBtns.forEach(btn => btn.onclick = () => bulkDeleteModal.style.display = 'none');
    confirmBulkDeleteBtn.onclick = confirmBulkDelete;



    const menuToggle = document.getElementById('mobile-menu-toggle');
    const sidebar = document.querySelector('.sidebar');
    const overlay = document.getElementById('sidebar-overlay');
    const navItems = document.querySelectorAll('.nav-item');
    const toggleSidebar = () => { sidebar.classList.toggle('active'); overlay.classList.toggle('active'); };
    menuToggle.onclick = toggleSidebar;
    overlay.onclick = toggleSidebar;
    navItems.forEach(item => { item.addEventListener('click', () => { if (window.innerWidth <= 1024) toggleSidebar(); }); });

    autoImportBtn.onclick = () => {
        importUrlInput.value = '';
        // Reset progress
        const bar = document.getElementById('full-import-bar');
        const status = document.getElementById('full-import-status');
        const progress = document.getElementById('full-import-progress');
        if (bar) { bar.style.width = '0%'; bar.style.background = 'var(--primary)'; }
        if (status) status.textContent = '';
        if (progress) progress.style.display = 'none';
        importModal.style.display = 'block';
    };

    closeImportModalBtns.forEach(btn => { btn.onclick = () => importModal.style.display = 'none'; });

    confirmImportBtn.onclick = async () => {
        let url = importUrlInput.value.trim();
        url = cleanVideoUrl(url); // Limpiar URL antes de enviar
        if (!url || !url.startsWith('http')) {

            showToast('Por favor ingresa una URL válida', 'error');
            return;
        }

        const progressDiv = document.getElementById('full-import-progress');
        const statusEl = document.getElementById('full-import-status');
        const barEl = document.getElementById('full-import-bar');

        confirmImportBtn.disabled = true;
        confirmImportBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Importando...';
        lucide.createIcons();
        if (progressDiv) progressDiv.style.display = 'block';
        if (barEl) barEl.style.width = '15%';
        if (statusEl) statusEl.textContent = 'Conectando y detectando temporadas...';

        try {
            // Animar la barra mientras espera
            let fakeProgress = 15;
            const ticker = setInterval(() => {
                if (fakeProgress < 80) {
                    fakeProgress += 3;
                    if (barEl) barEl.style.width = fakeProgress + '%';
                }
            }, 1500);

            const { data, error } = await supabaseClient.functions.invoke('import-full-series', {
                body: { url }
            });

            clearInterval(ticker);

            if (error) throw new Error(error.message || 'Error en el servidor');
            if (data && data.error) {
                if (data.error === 'CLOUDFLARE_BLOCKED') {
                    throw new Error('Cloudflare bloqueó el acceso. Prueba desde una red diferente o espera unos minutos.');
                }
                throw new Error(data.error);
            }

            if (barEl) { barEl.style.width = '100%'; barEl.style.background = 'var(--accent-green)'; }
            const msg = data.message || `¡Listo! ${data.total_episodes || 0} capítulos importados.`;
            if (statusEl) statusEl.textContent = msg;
            showToast(msg, 'success');

            await sleep(1800);
            importModal.style.display = 'none';
            await fetchContent();   // Recarga series/películas
            // Si estamos viendo una serie, recargar sus episodios también
            if (activeSeriesFilter) {
                const eps = await fetchEpisodesForSeries(activeSeriesFilter);
                allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
                allContent = allContent.concat(eps);
                populateSeasonSelect(activeSeriesFilter);
            }
            applyFilters();


        } catch (err) {
            if (barEl) { barEl.style.width = '0%'; }
            if (progressDiv) progressDiv.style.display = 'none';
            showToast('Error: ' + (err.message || 'Error desconocido'), 'error');
        } finally {
            confirmImportBtn.disabled = false;
            confirmImportBtn.innerHTML = '<i data-lucide="download-cloud"></i> Importar Todo';
            lucide.createIcons();
        }
    };

    // (Botón auto-import de temporada eliminado — usar importación de serie completa)
}


function closeModal() { contentModal.style.display = 'none'; }

function handleTypeChange() {
    if (typeSelect.value === 'episode') { seriesFields.classList.remove('hidden'); }
    else { seriesFields.classList.add('hidden'); }
}

function applyFilters() {
    const query = searchInput.value.toLowerCase();
    const category = filterCategory.value;
    let filtered = [];
    if (currentTab === 'movies') {
        filtered = allContent.filter(item => item.type === 'movie');
    } else if (currentTab === 'series') {
        if (activeSeriesFilter) {
            const season = filterSeason.value;
            filtered = allContent.filter(item => item.type === 'episode' && item.parent_id === activeSeriesFilter);
            if (season !== 'all') filtered = filtered.filter(item => item.season === parseInt(season));
            filtered.sort((a, b) => (a.season - b.season) || (a.episode - b.episode));
        } else {
            filtered = allContent.filter(item => item.type === 'series');
        }
    }
    filtered = filtered.filter(item => {
        const matchesSearch = item.title.toLowerCase().includes(query);
        const matchesCategory = category === 'all' || item.category === category;
        return matchesSearch && matchesCategory;
    });
    renderContent(filtered);
}

function showToast(message, type = 'success') {
    toastMessage.textContent = message;
    toast.className = 'toast';
    if (type === 'error') toast.classList.add('error');
    toast.classList.remove('hidden');
    toastIcon.setAttribute('data-lucide', type === 'error' ? 'alert-circle' : 'check-circle');
    lucide.createIcons();
    setTimeout(() => toast.classList.add('hidden'), 5000);
}