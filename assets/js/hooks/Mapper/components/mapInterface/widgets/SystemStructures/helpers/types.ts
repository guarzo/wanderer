export type StructureStatus = 'Powered' | 'Anchoring' | 'Unanchoring' | 'Low Power' | 'Abandoned' | 'Reinforced';

export interface StructureItem {
  id: string;
  typeId: string;
  type: string;
  name: string;
  owner: string;
  ownerId?: string;
  ownerTicker?: string;
  notes?: string;
  status: StructureStatus;
  endTime?: string;
  markedForDelete?: boolean;
  systemId?: string;
}

export const STRUCTURE_TYPE_MAP: Record<string, string> = {
  '4361': 'QA Fuel Control Tower',
  '12235': 'Amarr Control Tower',
  '12236': 'Gallente Control Tower',
  '16213': 'Caldari Control Tower',
  '16214': 'Minmatar Control Tower',
  '16286': 'QA Control Tower',
  '20059': 'Amarr Control Tower Medium',
  '20060': 'Amarr Control Tower Small',
  '20061': 'Caldari Control Tower Medium',
  '20062': 'Caldari Control Tower Small',
  '20063': 'Gallente Control Tower Medium',
  '20064': 'Gallente Control Tower Small',
  '20065': 'Minmatar Control Tower Medium',
  '20066': 'Minmatar Control Tower Small',
  '27530': 'Blood Control Tower',
  '27532': 'Dark Blood Control Tower',
  '27533': 'Guristas Control Tower',
  '27535': 'Dread Guristas Control Tower',
  '27536': 'Serpentis Control Tower',
  '27538': 'Shadow Control Tower',
  '27539': 'Angel Control Tower',
  '27540': 'Domination Control Tower',
  '27589': 'Blood Control Tower Medium',
  '27591': 'Dark Blood Control Tower Medium',
  '27592': 'Blood Control Tower Small',
  '27594': 'Dark Blood Control Tower Small',
  '27595': 'Guristas Control Tower Medium',
  '27597': 'Dread Guristas Control Tower Medium',
  '27598': 'Guristas Control Tower Small',
  '27600': 'Dread Guristas Control Tower Small',
  '27601': 'Serpentis Control Tower Medium',
  '27603': 'Shadow Control Tower Medium',
  '27604': 'Serpentis Control Tower Small',
  '27606': 'Shadow Control Tower Small',
  '27607': 'Angel Control Tower Medium',
  '27609': 'Domination Control Tower Medium',
  '27610': 'Angel Control Tower Small',
  '27612': 'Domination Control Tower Small',
  '27780': 'Sansha Control Tower',
  '27782': 'Sansha Control Tower Medium',
  '27784': 'Sansha Control Tower Small',
  '27786': 'True Sansha Control Tower',
  '27788': 'True Sansha Control Tower Medium',
  '27790': 'True Sansha Control Tower Small',
  '35825': 'Raitaru',
  '35826': 'Azbel',
  '35827': 'Sotiyo',
  '35832': 'Astrahus',
  '35833': 'Fortizar',
  '35834': 'Keepstar',
  '35835': 'Athanor',
  '35836': 'Tatara',
  '40340': 'Upwell Palatine Keepstar',
  '47512': "'Moreau' Fortizar",
  '47513': "'Draccous' Fortizar",
  '47514': "'Horizon' Fortizar",
  '47515': "'Marginis' Fortizar",
  '47516': "'Prometheus' Fortizar",
};
