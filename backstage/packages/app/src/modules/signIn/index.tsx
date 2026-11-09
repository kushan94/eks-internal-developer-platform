import { SignInPage } from '@backstage/core-components';
import {
  createFrontendModule,
  githubAuthApiRef,
} from '@backstage/frontend-plugin-api';
import { SignInPageBlueprint } from '@backstage/plugin-app-react';

const github = {
  id: 'github-auth-provider',
  title: 'GitHub',
  message: 'Sign in with your GitHub account',
  apiRef: githubAuthApiRef,
};

// Guest sign-in is only offered when running locally with `yarn start`.
const providers =
  process.env.NODE_ENV === 'development' ? (['guest', github] as const) : [github];

const signInPage = SignInPageBlueprint.make({
  params: {
    loader: async () => props => (
      <SignInPage {...props} providers={[...providers]} />
    ),
  },
});

export const signInModule = createFrontendModule({
  pluginId: 'app',
  extensions: [signInPage],
});
