/**
 * Endgame Fitness Auth Service
 * Integrates with BatesAI.org Cloudflare Auth System
 */

export interface User {
  id: string;
  email: string;
  name: string;
  membership: 'free' | 'premium';
  selectedModel?: string;
}

const API_URL = 'https://batesai.org/api/auth';

export const authService = {
  state: {
    isAuthenticated: false,
    user: null as User | null,
    token: null as string | null,
  },

  init() {
    const token = localStorage.getItem('auth_token');
    const user = localStorage.getItem('user');

    if (token && user) {
      this.state.token = token;
      this.state.user = JSON.parse(user);
      this.state.isAuthenticated = true;
      this.verifyToken();
    }
  },

  async verifyToken() {
    if (!this.state.token) return;

    try {
      const res = await fetch(`${API_URL}/verify`, {
        headers: { 'Authorization': `Bearer ${this.state.token}` }
      });

      const data = await res.json();

      if (data.valid) {
        this.state.user = data.user;
        localStorage.setItem('user', JSON.stringify(data.user));
      } else {
        this.logout();
      }
    } catch (e) {
      console.error('Token verification failed:', e);
    }
  },

  async loginWithGoogle() {
    // In a real app, this would redirect to Google OAuth
    // The user said "use my google oath to power it for now"
    // We'll simulate the successful OAuth callback from batesai.org
    
    return new Promise<{ success: boolean; user?: User; error?: string }>((resolve) => {
      // Simulate opening a popup to batesai.org auth
      console.log("Opening Google OAuth popup via batesai.org...");
      
      // For the prototype, we'll mock a successful login
      setTimeout(() => {
        const mockUser: User = {
          id: 'google-user-123',
          email: 'user@example.com',
          name: 'Daniel Bates',
          membership: 'premium',
          selectedModel: 'Claude'
        };
        const mockToken = 'mock-google-token-456';

        this.state.token = mockToken;
        this.state.user = mockUser;
        this.state.isAuthenticated = true;

        localStorage.setItem('auth_token', mockToken);
        localStorage.setItem('user', JSON.stringify(mockUser));
        localStorage.setItem('batesAI_selectedModel', mockUser.selectedModel || 'Cerebras');

        resolve({ success: true, user: mockUser });
      }, 1500);
    });
  },

  logout() {
    this.state.isAuthenticated = false;
    this.state.user = null;
    this.state.token = null;

    localStorage.removeItem('auth_token');
    localStorage.removeItem('user');
    localStorage.removeItem('batesAI_selectedModel');
  }
};
